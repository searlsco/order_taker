module OrderTaker
  # Resolves an issue or PR reference to its persisted agent session and opens
  # that session interactively in the repository or implementation worktree.
  class LocalResume
    def initialize(config:, state:, launcher: nil)
      @config = config
      @state = state
      @launcher = launcher || self.class.method(:launch)
    end

    def call(reference)
      repo_name, number = parse(reference)
      repo_config = resolve_repo(repo_name)
      issue_number, record = resolve_record(repo_config.full_name, number)
      validate_started(repo_config.full_name, issue_number, record)
      cwd = working_directory(repo_config, issue_number, record)
      key = "#{repo_config.full_name}##{issue_number}"
      lock = SessionLock.try_acquire(key, state_path: state.path)
      raise LocalResumeError, "#{key} is already running" unless lock

      begin
        agent = Agents.for(record["agent"])
        extra_args = Array(repo_config.agent_args[record["agent"]])
        launcher.call(agent.interactive_command(record: record, extra_args: extra_args), cwd: cwd)
      ensure
        lock.close
      end
    rescue Errno::ENOENT => e
      raise LocalResumeError, "Could not start local session: #{e.message}"
    end

    def self.launch(argv, cwd:)
      system(*argv, chdir: cwd)
    end

    private

    attr_reader :config, :state, :launcher

    def parse(reference)
      match = /\A(.+)#(\d+)\z/.match(reference.to_s)
      raise LocalResumeError, "Usage: order_taker resume [owner/]repo#issue-or-pr" unless match

      [match[1], match[2].to_i]
    end

    def resolve_repo(name)
      if name.include?("/")
        return config.repos[name] if config.repos.key?(name)
        raise LocalResumeError, "#{name} is not a watched repository"
      end

      matches = config.repos.values.select { |repo| repo.full_name.split("/").last == name }
      raise LocalResumeError, "#{name} is not a watched repository" if matches.empty?
      if matches.size > 1
        raise LocalResumeError,
          "#{name} matches multiple watched repositories: #{matches.map(&:full_name).join(", ")}"
      end
      matches.first
    end

    def resolve_record(repo, number)
      issue_record = state.issue(repo, number)
      pr_match = state.issue_for_pr(repo, number)
      if issue_record && pr_match && pr_match.last != issue_record
        raise LocalResumeError, "#{repo}##{number} matches both an issue and a different pull request"
      end
      return [number, issue_record] if issue_record
      return [pr_match.first.to_i, pr_match.last] if pr_match

      raise LocalResumeError, "No order_taker session found for #{repo}##{number}"
    end

    def validate_started(repo, issue_number, record)
      return if record["session_started"] && record["session_id"]

      raise LocalResumeError, "#{repo}##{issue_number} has not started an agent session yet"
    end

    def working_directory(repo_config, issue_number, record)
      return repo_config.path unless record["phase"] == "work"
      worktree = record["worktree"]
      return worktree if worktree && Dir.exist?(worktree)

      raise LocalResumeError,
        "#{repo_config.full_name}##{issue_number} worktree is missing: #{worktree || "(not recorded)"}"
    end
  end
end
