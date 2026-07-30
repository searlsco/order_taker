require "json"
require "fileutils"

module OrderTaker
  # Persistent daemon state: per-repo poll cursors and per-thread session records.
  # A "thread" is an issue or PR number in a repo; sessions are keyed by "owner/name#123".
  class State
    DIR = File.join(Dir.home, ".local", "state", "order_taker")
    PATH = File.join(DIR, "state.json")

    attr_reader :path, :data

    def initialize(path = PATH)
      @path = path
      @data = File.exist?(path) ? JSON.parse(File.read(path)) : {"repos" => {}}
    end

    def save
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, path)
    end

    def repo(full_name)
      data["repos"][full_name] ||= {"cursors" => {}, "issues" => {}}
    end

    def cursor(full_name, kind)
      repo(full_name)["cursors"][kind]
    end

    def set_cursor(full_name, kind, iso8601)
      repo(full_name)["cursors"][kind] = iso8601
    end

    def issue(full_name, number)
      repo(full_name)["issues"][number.to_s]
    end

    def ensure_issue(full_name, number, agent:)
      repo(full_name)["issues"][number.to_s] ||= {
        "agent" => agent,
        "session_id" => nil,
        "phase" => "plan",
        "worktree" => nil,
        "branch" => nil,
        "pr_number" => nil,
        "pending_events" => []
      }
    end

    def issues(full_name)
      repo(full_name)["issues"]
    end

    # Finds the issue record (and number) whose PR is the given number,
    # so PR activity routes to the originating issue's session.
    def issue_for_pr(full_name, pr_number)
      issues(full_name).find { |_number, record| record["pr_number"] == pr_number }
    end

    def append_events(full_name, number, events)
      issue(full_name, number)["pending_events"].concat(events)
    end

    def consume_events(full_name, number, count)
      issue(full_name, number)["pending_events"].shift(count)
    end
  end
end
