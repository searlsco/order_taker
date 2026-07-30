require "json"
require "open3"

module OrderTaker
  # Thin wrapper around the gh CLI, which supplies all GitHub auth (the bot account).
  class Gh
    GhError = Class.new(Error)

    def api(path, paginate: false)
      args = ["gh", "api", path]
      args += ["--paginate", "--slurp"] if paginate
      out = run(args)
      return [] if out.strip.empty?
      parsed = JSON.parse(out)
      paginate ? parsed.flatten(1) : parsed # --slurp returns an array of pages
    end

    def login
      @login ||= run(["gh", "api", "user", "--jq", ".login"]).strip
    end

    def post_comment(repo, number, body)
      run(["gh", "api", "repos/#{repo}/issues/#{number}/comments", "-f", "body=#{truncate(body)}"])
    end

    private

    def truncate(body, limit = 60_000)
      return body if body.length <= limit
      body[0, limit] + "\n\n…(truncated by order_taker)"
    end

    def run(args)
      out, err, status = Open3.capture3(*args)
      raise GhError, "#{args.join(" ")} failed: #{err.strip}" unless status.success?
      out
    end
  end
end
