require "json"

module OrderTaker
  # Builds CLI invocations for each supported agent and extracts the final
  # message (and session identity) from a completed run.
  module Agents
    def self.for(name)
      case name
      when "claude" then Claude
      when "codex" then Codex
      else raise Error, "Unknown agent: #{name}"
      end
    end

    module Claude
      # Sessions are minted with a deterministic UUID so resumes need no capture.
      def self.command(prompt:, record:, extra_args: [], worktree: nil, out_file: nil)
        argv = ["claude", "-p", "--dangerously-skip-permissions"]
        argv += if record["session_started"]
          ["--resume", record["session_id"]]
        else
          ["--session-id", record["session_id"]]
        end
        argv += ["--add-dir", worktree] if worktree
        argv += extra_args
        argv += ["--", prompt]
      end

      def self.extract(result, record, out_file: nil)
        {"message" => result.stdout.strip, "session_id" => record["session_id"]}
      end
    end

    module Codex
      # codex assigns its own thread id; we parse it from --json events on the
      # first run and resume by id thereafter. The final message goes to a file.
      def self.command(prompt:, record:, extra_args: [], worktree: nil, out_file:)
        argv = ["codex", "exec"]
        argv += ["resume", record["session_id"]] if record["session_started"]
        argv += ["--dangerously-bypass-approvals-and-sandbox", "--json", "-o", out_file]
        argv += extra_args
        argv << prompt
      end

      def self.extract(result, record, out_file:)
        session_id = record["session_id"] || result.stdout.each_line.filter_map { |line|
          event = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          event["thread_id"] if event && event["type"] == "thread.started"
        }.first
        message = File.exist?(out_file) ? File.read(out_file).strip : ""
        {"message" => message, "session_id" => session_id}
      end
    end
  end
end
