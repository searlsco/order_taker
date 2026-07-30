require "fileutils"
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
        end
        state.save
        true
      end
    end

    def finish(key, run)
      result = run[:thread].value
      repo, number = run[:repo], run[:number]
      record = state.issue(repo, number)
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
          start_run(repo_config, number.to_i, record, key)
        end
      end
    end

    def start_run(repo_config, number, record, key)
      repo = repo_config.full_name
      events = record["pending_events"].dup
      prompt = build_prompt(repo_config, number, record, events)
      agent = Agents.for(record["agent"])
      out_file = File.join(State::DIR, "runs", key.tr("/#", "--"), "last_message.txt")
      FileUtils.mkdir_p(File.dirname(out_file))
      FileUtils.rm_f(out_file)

      argv = agent.command(
        prompt: prompt,
        record: record,
        extra_args: Array(record_agent_args(repo_config, record)),
        worktree: (record["worktree"] if record["phase"] == "work"),
        out_file: out_file
      )
      timeout = config.run_timeout_seconds
      thread = Thread.new { @runner.run(argv, cwd: repo_config.path, timeout: timeout) }
      runs[key] = {
        thread: thread,
        repo: repo,
        number: number,
        batch_size: events.size,
        agent: agent,
        out_file: out_file
      }
      log.call("#{key}: started #{record["agent"]} run (#{record["phase"]} phase, #{events.size} event(s))")
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
