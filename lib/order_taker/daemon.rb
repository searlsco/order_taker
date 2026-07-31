require "fileutils"
require "json"
require "time"

module OrderTaker
  # Main loop: reap finished agent runs, poll for activity, wind down closed
  # threads, and start new runs up to the concurrency cap. All conversation
  # state lives in the agents' own sessions; the daemon only routes events.
  class Daemon
    def initialize(config:, state:, gh:, log: nil, runner: Runner)
      @config = config
      @state = state
      @gh = gh
      @log = log || self.class.method(:default_log)
      @runner = runner
      @gatherer = Gatherer.new(config: config, state: state, gh: gh, log: @log)
      @runs = {}
      @stop = false
    end

    def run
      %w[INT TERM].each { |signal| trap(signal) { @stop = true } }
      log.call("order_taker #{VERSION} watching #{config.repos.keys.join(", ")} as @#{gh.login}")
      until @stop
        tick
        interruptible_sleep(config.poll_interval_seconds)
      end
      log.call("shutting down (#{runs.size} run(s) in flight will re-run on restart)")
    end

    def tick
      reap
      gatherer.poll.each { |wind_down| request_wind_down(wind_down) }
      sweep_wind_downs
      state.save
      start_runs
      state.save
    rescue Gh::GhError => e
      log.call("gh error (will retry next tick): #{e.message}")
    end

    private

    attr_reader :config, :state, :gh, :log, :gatherer, :runs

    def reap
      runs.reject! do |key, run|
        next false if run[:thread].alive?
        begin
          finish(key, run)
        rescue => e
          log.call("#{key}: error finishing run: #{e.class}: #{e.message}")
          state.consume_events(run[:repo], run[:number], run[:batch_size])
        ensure
          run[:lock].close
        end
        state.save
        true
      end
    end

    def finish(key, run)
      result = run[:thread].value
      repo, number = run[:repo], run[:number]
      record = state.issue(repo, number)
      persist_run_artifacts(run, result)
      extracted = run[:agent].extract(result, record, out_file: run[:out_file])
      state.consume_events(repo, number, run[:batch_size])

      if result.success? && !extracted["message"].empty?
        record["session_started"] = true
        record["session_id"] ||= extracted["session_id"]
        post_comment(repo, number, extracted["message"])
        log.call("#{key}: run finished, comment posted")
      else
        reason = result.timed_out ? "timed out after #{config.run_timeout_seconds}s" : "exited #{result.exit_status}"
        stderr_tail = result.stderr.to_s.lines.last(20).join
        post_comment(repo, number, <<~MD)
          ⚠️ order_taker: #{record["agent"]} run #{reason}.

          ```
          #{stderr_tail.strip}
          ```

          Full logs saved locally under `#{display_path(run[:run_dir])}`.

          Reply here to try again.
        MD
        log.call("#{key}: run failed (#{reason})")
      end

      detect_pr(repo, number, record)
    end

    def post_comment(repo, number, body)
      gh.post_comment(repo, number, body)
    rescue Gh::GhError => e
      log.call("#{repo}##{number}: failed to post comment: #{e.message}\n--- unposted message ---\n#{body}\n---")
    end

    def detect_pr(repo, number, record)
      return unless record["phase"] == "work" && record["pr_number"].nil? && record["branch"]
      owner = repo.split("/").first
      prs = gh.api("repos/#{repo}/pulls?head=#{owner}:#{record["branch"]}&state=all")
      if (pr = prs.first)
        record["pr_number"] = pr["number"]
        log.call("#{repo}##{number}: opened PR ##{pr["number"]}")
      end
    rescue Gh::GhError => e
      log.call("#{repo}##{number}: PR lookup failed: #{e.message}")
    end

    def request_wind_down(wind_down)
      record = state.issue(wind_down[:repo], wind_down[:number])
      return unless record && record["phase"] != "archived"
      record["pending_wind_down"] = {"merged" => wind_down[:merged]}
    end

    # Wind-downs wait until the thread has no run in flight (never yank a
    # worktree out from under a working agent).
    def sweep_wind_downs
      config.repos.each_value do |repo_config|
        state.issues(repo_config.full_name).each do |number, record|
          next unless record["pending_wind_down"]
          next if runs.key?(run_key(repo_config.full_name, number))
          wind_down(repo_config, number.to_i, record)
        end
      end
    end

    def wind_down(repo_config, number, record)
      merged = record["pending_wind_down"]["merged"]
      begin
        Worktrees.cleanup(repo_config.path, record["worktree"], record["branch"], merged: merged)
      rescue Worktrees::GitError => e
        log.call("#{repo_config.full_name}##{number}: worktree cleanup failed: #{e.message}")
      end
      record["phase"] = "archived"
      record["worktree"] = nil
      record["pending_events"] = []
      record.delete("pending_wind_down")
      log.call("#{repo_config.full_name}##{number}: wound down (#{merged ? "merged" : "closed"})")
    end

    def start_runs
      config.repos.each_value do |repo_config|
        state.issues(repo_config.full_name).each do |number, record|
          return if runs.size >= config.max_concurrent_runs
          key = run_key(repo_config.full_name, number)
          next if runs.key?(key)
          next if record["phase"] == "archived" || record["pending_wind_down"]
          next if record["pending_events"].empty?
          lock = SessionLock.try_acquire(key, state_path: state.path)
          next unless lock
          begin
            start_run(repo_config, number.to_i, record, key, lock)
          rescue
            lock.close
            raise
          end
        end
      end
    end

    def start_run(repo_config, number, record, key, lock)
      repo = repo_config.full_name
      events = record["pending_events"].dup
      prompt = build_prompt(repo_config, number, record, events)
      agent = Agents.for(record["agent"])
      started_at = Time.now.utc
      run_dir = File.join(
        File.dirname(state.path),
        "runs",
        key.tr("/#", "--"),
        started_at.strftime("%Y%m%dT%H%M%S.%6NZ")
      )
      FileUtils.mkdir_p(run_dir)
      out_file = File.join(run_dir, "last_message.txt")

      argv = agent.command(
        prompt: prompt,
        record: record,
        extra_args: Array(record_agent_args(repo_config, record)),
        worktree: (record["worktree"] if record["phase"] == "work"),
        out_file: out_file
      )
      timeout = config.run_timeout_seconds
      run = {
        repo: repo,
        number: number,
        batch_size: events.size,
        agent: agent,
        agent_name: record["agent"],
        session_id: record["session_id"],
        phase: record["phase"],
        out_file: out_file,
        run_dir: run_dir,
        stdout_path: File.join(run_dir, "stdout.log"),
        stderr_path: File.join(run_dir, "stderr.log"),
        started_at: started_at,
        started_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        lock: lock
      }
      write_run_manifest(run, status: "running")
      run[:thread] = Thread.new do
        @runner.run(
          argv,
          cwd: repo_config.path,
          timeout: timeout,
          stdout_path: run[:stdout_path],
          stderr_path: run[:stderr_path]
        )
      end
      runs[key] = run
      log.call("#{key}: started #{record["agent"]} run (#{record["phase"]} phase, #{events.size} event(s))")
    end

    def persist_run_artifacts(run, result)
      File.write(run[:stdout_path], result.stdout.to_s) unless File.exist?(run[:stdout_path])
      File.write(run[:stderr_path], result.stderr.to_s) unless File.exist?(run[:stderr_path])
      write_run_manifest(run, status: result.success? ? "succeeded" : "failed", result: result)
      log.call("#{run[:repo]}##{run[:number]}: run artifacts saved to #{display_path(run[:run_dir])}")
    end

    def write_run_manifest(run, status:, result: nil)
      finished_at = Time.now.utc if result
      manifest = {
        "repo" => run[:repo],
        "number" => run[:number],
        "agent" => run[:agent_name],
        "session_id" => run[:session_id],
        "phase" => run[:phase],
        "status" => status,
        "started_at" => run[:started_at].iso8601(6),
        "stdout" => "stdout.log",
        "stderr" => "stderr.log"
      }
      if result
        manifest.merge!(
          "finished_at" => finished_at.iso8601(6),
          "elapsed_seconds" => (
            Process.clock_gettime(Process::CLOCK_MONOTONIC) - run[:started_monotonic]
          ).round(3),
          "exit_status" => result.exit_status,
          "timed_out" => result.timed_out
        )
      end
      File.write(File.join(run[:run_dir], "run.json"), JSON.pretty_generate(manifest))
    end

    def display_path(path)
      path.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
    end

    def build_prompt(repo_config, number, record, events)
      repo = repo_config.full_name
      if record["phase"] == "plan" && events.any? { |event| Triggers.go?("#{event["title"]} #{event["body"]}", config.go_word) }
        worktree = Worktrees.prepare(repo_config.path, repo, number)
        record["phase"] = "work"
        record["worktree"] = worktree["path"]
        record["branch"] = worktree["branch"]
        Prompts.work(repo: repo, number: number, events: events,
          worktree: worktree["path"], branch: worktree["branch"], default_branch: worktree["default_branch"])
      elsif record["phase"] == "work"
        Prompts.work_resume(repo: repo, number: number, events: events,
          worktree: record["worktree"], branch: record["branch"])
      elsif record["session_started"]
        Prompts.resume(repo: repo, number: number, events: events)
      else
        Prompts.plan(repo: repo, number: number, events: events)
      end
    end

    def record_agent_args(repo_config, record)
      repo_config.agent_args[record["agent"]]
    end

    def run_key(repo, number)
      "#{repo}##{number}"
    end

    def interruptible_sleep(seconds)
      seconds.times do
        return if @stop
        sleep 1
      end
    end

    def self.default_log(message)
      puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{message}"
      $stdout.flush
    end
  end
end
