require "json"

module OrderTaker
  class Config
    PATH = File.join(Dir.home, ".config", "order_taker", "config.json")

    RepoConfig = Struct.new(:full_name, :path, :default_agent, :agent_args, keyword_init: true)

    attr_reader :authorized_authors, :go_word, :default_agent, :repos,
      :poll_interval_seconds, :max_concurrent_runs, :run_timeout_seconds

    def self.load(path = PATH)
      raise ConfigError, "No config found at #{path}. Run `order_taker init` to create one." unless File.exist?(path)
      new(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))
    rescue JSON::ParserError => e
      raise ConfigError, "Could not parse #{path}: #{e.message}"
    end

    def initialize(json)
      @authorized_authors = require_key(json, "authorized_authors")
      raise ConfigError, "authorized_authors must be a non-empty array of GitHub handles" unless @authorized_authors.is_a?(Array) && !@authorized_authors.empty?
      @authorized_authors = @authorized_authors.map(&:downcase)

      @go_word = require_key(json, "go_word").to_s.downcase
      raise ConfigError, "go_word must not be blank" if @go_word.strip.empty?

      @default_agent = json.fetch("default_agent", "claude")
      raise ConfigError, "default_agent must be \"claude\" or \"codex\"" unless %w[claude codex].include?(@default_agent)

      @poll_interval_seconds = json.fetch("poll_interval_seconds", 60)
      @max_concurrent_runs = json.fetch("max_concurrent_runs", 2)
      @run_timeout_seconds = json.fetch("run_timeout_seconds", 3600)

      repos = require_key(json, "repos")
      raise ConfigError, "repos must be a non-empty object keyed by owner/name" unless repos.is_a?(Hash) && !repos.empty?
      @repos = repos.to_h { |full_name, repo|
        raise ConfigError, "repos.#{full_name} must set path (a local clone)" unless repo.is_a?(Hash) && repo["path"]
        path = File.expand_path(repo["path"])
        agent = repo.fetch("default_agent", @default_agent)
        raise ConfigError, "repos.#{full_name}.default_agent must be \"claude\" or \"codex\"" unless %w[claude codex].include?(agent)
        [full_name, RepoConfig.new(
          full_name: full_name,
          path: path,
          default_agent: agent,
          agent_args: repo.fetch("agent_args", {})
        )]
      }
    end

    def repo(full_name)
      repos.fetch(full_name)
    end

    def authorized?(login)
      authorized_authors.include?(login.to_s.downcase)
    end

    EXAMPLE = <<~JSON
      {
        "authorized_authors": ["searls", "bitsly"],
        "go_word": "roadhouse",
        "default_agent": "claude",
        "poll_interval_seconds": 60,
        "max_concurrent_runs": 2,
        "run_timeout_seconds": 3600,
        "repos": {
          "searls/example": {
            "path": "~/code/searls/example",
            "default_agent": "claude",
            "agent_args": {"claude": [], "codex": []}
          }
        }
      }
    JSON

    private

    def require_key(json, key)
      raise ConfigError, "Config is missing required key: #{key}" unless json.key?(key)
      json[key]
    end
  end
end
