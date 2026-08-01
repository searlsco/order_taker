require "fileutils"

module OrderTaker
  class Cli
    def initialize(config: Config, launchd: Launchd)
      @config = config
      @launchd = launchd
    end

    def call(argv)
      case argv.first
      when "run" then run
      when "install" then install
      when "uninstall" then uninstall
      when "restart" then restart
      when "init" then init
      when "status" then status
      when "resume" then return resume(argv[1]) ? 0 : 1
      when "version", "--version", "-v" then puts VERSION
      else help
      end
      0
    rescue ConfigError, LocalResumeError => e
      warn e.message
      1
    end

    private

    attr_reader :config, :launchd

    def run
      config = Config.load
      Daemon.new(config: config, state: State.new, gh: Gh.new).run
    end

    def install
      Config.load # fail fast on bad config before installing
      bin_path = File.expand_path($PROGRAM_NAME)
      plist = Launchd.install(bin_path)
      puts "Installed and loaded #{plist}"
      puts "Logs: #{Launchd::LOG_DIR}"
    end

    def uninstall
      plist = Launchd.uninstall
      puts "Unloaded and removed #{plist}"
    end

    def restart
      config.load # fail fast on invalid config before restarting
      puts "Restarted #{launchd.restart}"
    end

    def init
      if File.exist?(Config::PATH)
        puts "Config already exists at #{Config::PATH}"
      else
        FileUtils.mkdir_p(File.dirname(Config::PATH))
        File.write(Config::PATH, Config::EXAMPLE)
        puts "Wrote example config to #{Config::PATH}. Edit it, then run `order_taker install`."
      end
    end

    def status
      config = Config.load
      state = State.new
      config.repos.each_key do |repo|
        puts repo
        issues = state.issues(repo)
        if issues.empty?
          puts "  (no sessions)"
          next
        end
        issues.each do |number, record|
          parts = ["##{number}", record["agent"], record["phase"]]
          parts << "PR ##{record["pr_number"]}" if record["pr_number"]
          parts << "#{record["pending_events"].size} pending event(s)" unless record["pending_events"].empty?
          puts "  #{parts.join("  ")}"
        end
      end
    end

    def resume(reference)
      raise LocalResumeError, "Usage: order_taker resume [owner/]repo#issue-or-pr" unless reference

      LocalResume.new(config: Config.load, state: State.new).call(reference)
    end

    def help
      puts <<~TXT
        order_taker #{VERSION}: GitHub-driven agent sessions

        Usage: order_taker <command>

          init       Write an example config to #{Config::PATH}
          run        Run the daemon in the foreground
          install    Install and load the launchd agent
          uninstall  Unload and remove the launchd agent
          restart    Restart the launchd agent and reload configuration
          status     Show watched repos and session state
          resume     Continue locally: resume [owner/]repo#issue-or-pr
          version    Print version
      TXT
    end
  end
end
