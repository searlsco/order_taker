require "time"

module OrderTaker
  # Polls GitHub for new activity on watched repos, appends normalized events
  # to per-thread session records, and reports threads whose PR or issue
  # closed (so the daemon can wind them down).
  #
  # The authorization boundary lives here: only activity from authorized
  # authors creates or resumes sessions. When an authorized author engages an
  # unknown thread, that engagement opts the whole thread in, so its prior
  # context (whoever wrote it) seeds the session.
  class Gatherer
    def initialize(config:, state:, gh:, log:)
      @config = config
      @state = state
      @gh = gh
      @log = log
    end

    # Returns [{repo:, number:, merged:}] wind-downs discovered this poll
    def poll
      config.repos.values.flat_map { |repo_config|
        poll_repo(repo_config)
      }
    end

    private

    attr_reader :config, :state, :gh, :log

    CURSORS = %w[issues comments review_comments reviews]

    def poll_repo(repo_config)
      repo = repo_config.full_name
      if state.cursor(repo, "issues").nil?
        now = Time.now.utc.iso8601
        CURSORS.each { |kind| state.set_cursor(repo, kind, now) }
        log.call("#{repo}: initialized cursors at #{now}; watching for new activity")
        return []
      end

      wind_downs = poll_issues(repo_config)
      wind_downs.concat(poll_comments(repo_config))
      wind_downs.concat(poll_review_comments(repo_config))
      wind_downs.concat(poll_reviews(repo_config))
      wind_downs.uniq
    end

    def poll_issues(repo_config)
      repo = repo_config.full_name
      cursor = state.cursor(repo, "issues")
      items = gh.api("repos/#{repo}/issues?state=all&sort=updated&direction=asc&since=#{cursor}&per_page=100", paginate: true)
      wind_downs = []
      max_seen = cursor

      items.each do |item|
        max_seen = [max_seen, item["updated_at"].to_s].max
        number = item["number"]
        author = item.dig("user", "login")
        pr = item["pull_request"]

        if !pr && item["created_at"] > cursor && authorized_human?(author) &&
            !ignored?("#{item["title"]}\n#{item["body"]}") &&
            !cleanup?("#{item["title"]}\n#{item["body"]}")
          open_session(repo_config, item)
        end

        if item["state"] == "closed" && item["closed_at"].to_s > cursor
          wind_downs.concat(wind_downs_for(repo, number, pr))
        end
      end

      state.set_cursor(repo, "issues", max_seen)
      wind_downs.uniq
    end

    def wind_downs_for(repo, number, pr)
      targets = []
      if pr
        merged = !pr["merged_at"].nil?
        if (found = state.issue_for_pr(repo, number))
          targets << {repo: repo, number: found.first.to_i, merged: merged}
        end
      elsif live_record?(repo, number)
        targets << {repo: repo, number: number, merged: false}
      end
      targets.select { |t| live_record?(t[:repo], t[:number]) }
    end

    def poll_comments(repo_config)
      repo = repo_config.full_name
      cursor = state.cursor(repo, "comments")
      items = gh.api("repos/#{repo}/issues/comments?since=#{cursor}&per_page=100", paginate: true)
      wind_downs = []
      max_seen = cursor

      items.sort_by { |c| c["created_at"] }.each do |comment|
        created = comment["created_at"]
        next unless created > cursor # since= matches edits; only react to new comments
        max_seen = [max_seen, created].max
        author = comment.dig("user", "login")
        next unless authorized_human?(author)

        number = comment["issue_url"][%r{/(\d+)\z}, 1].to_i
        if cleanup?(comment["body"])
          wind_downs.concat([cleanup_wind_down(repo, number)].compact)
          next
        end
        next if ignored?(comment["body"])

        if (target = route_target(repo, number))
          state.append_events(repo, target, [comment_event(comment)])
        else
          enroll(repo_config, number, seed_comment: comment)
        end
      end

      state.set_cursor(repo, "comments", max_seen)
      wind_downs
    end

    def poll_review_comments(repo_config)
      repo = repo_config.full_name
      cursor = state.cursor(repo, "review_comments")
      items = gh.api("repos/#{repo}/pulls/comments?since=#{cursor}&per_page=100", paginate: true)
      wind_downs = []
      max_seen = cursor

      items.sort_by { |c| c["created_at"] }.each do |comment|
        created = comment["created_at"]
        next unless created > cursor
        max_seen = [max_seen, created].max
        author = comment.dig("user", "login")
        next unless authorized_human?(author)

        pr_number = comment["pull_request_url"][%r{/(\d+)\z}, 1].to_i
        if cleanup?(comment["body"])
          wind_downs.concat([cleanup_wind_down(repo, pr_number)].compact)
          next
        end
        next if ignored?(comment["body"])

        next unless (target = route_target(repo, pr_number))
        state.append_events(repo, target, [{
          "type" => "review_comment",
          "author" => author,
          "path" => comment["path"],
          "body" => comment["body"].to_s
        }])
      end

      state.set_cursor(repo, "review_comments", max_seen)
      wind_downs
    end

    # Review summaries (approve/request-changes bodies) have no since-filtered
    # list endpoint, so fetch per open session that has a PR.
    def poll_reviews(repo_config)
      repo = repo_config.full_name
      cursor = state.cursor(repo, "reviews")
      wind_downs = []
      max_seen = cursor

      state.issues(repo).each do |number, record|
        next if record["phase"] == "archived" || record["pr_number"].nil?
        reviews = gh.api("repos/#{repo}/pulls/#{record["pr_number"]}/reviews")
        reviews.each do |review|
          submitted = review["submitted_at"].to_s
          next unless submitted > cursor
          max_seen = [max_seen, submitted].max
          author = review.dig("user", "login")
          next unless authorized_human?(author)
          if cleanup?(review["body"])
            wind_downs << {repo: repo, number: number.to_i, merged: false}
            next
          end
          next if ignored?(review["body"])
          next if review["state"] == "COMMENTED" && review["body"].to_s.empty? # container for inline comments

          state.append_events(repo, number.to_i, [{
            "type" => "review",
            "author" => author,
            "state" => review["state"],
            "body" => review["body"].to_s
          }])
        end
      end

      state.set_cursor(repo, "reviews", max_seen)
      wind_downs
    end

    def open_session(repo_config, issue)
      repo = repo_config.full_name
      number = issue["number"]
      agent = Triggers.agent_for("#{issue["title"]}\n#{issue["body"]}", default: repo_config.default_agent)
      record = state.ensure_issue(repo, number, agent: agent)
      record["session_id"] ||= SessionKey.uuid(repo, number) if record["agent"] == "claude"
      state.append_events(repo, number, [{
        "type" => "issue_opened",
        "author" => issue.dig("user", "login"),
        "title" => issue["title"],
        "body" => issue["body"].to_s
      }])
      log.call("#{repo}##{number}: new session (#{record["agent"]})")
    end

    # An authorized comment on a thread we've never seen: opt it in, seeded
    # with the full prior thread (minus our own bot's comments).
    def enroll(repo_config, number, seed_comment:)
      repo = repo_config.full_name
      issue = gh.api("repos/#{repo}/issues/#{number}")
      record = state.ensure_issue(repo, number, agent: Triggers.agent_for("#{issue["title"]}\n#{issue["body"]}", default: repo_config.default_agent))
      record["session_id"] ||= SessionKey.uuid(repo, number) if record["agent"] == "claude"
      record["pr_number"] = number if issue.key?("pull_request")

      events = [{
        "type" => "issue_opened",
        "author" => issue.dig("user", "login"),
        "title" => issue["title"],
        "body" => issue["body"].to_s
      }]
      gh.api("repos/#{repo}/issues/#{number}/comments?per_page=100", paginate: true).each do |comment|
        next if comment["id"] == seed_comment["id"]
        next if bot?(comment.dig("user", "login"))
        events << comment_event(comment)
      end
      events << comment_event(seed_comment)
      state.append_events(repo, number, events)
      log.call("#{repo}##{number}: enrolled existing thread (#{record["agent"]})")
    end

    # Routes activity on thread `number` to its session: directly, or from a
    # PR to the issue that spawned it. Re-engaging an archived session revives
    # it back to the plan phase.
    def route_target(repo, number)
      target = if state.issue(repo, number)
        number
      elsif (found = state.issue_for_pr(repo, number))
        found.first.to_i
      end
      return nil unless target

      record = state.issue(repo, target)
      if record["phase"] == "archived"
        record["phase"] = "plan"
        record["worktree"] = nil
        record["branch"] = nil
        log.call("#{repo}##{target}: revived archived session")
      end
      target
    end

    def live_record?(repo, number)
      (record = state.issue(repo, number)) && record["phase"] != "archived"
    end

    def cleanup_wind_down(repo, number)
      target = if state.issue(repo, number)
        number
      elsif (found = state.issue_for_pr(repo, number))
        found.first.to_i
      end
      return unless target && live_record?(repo, target)

      {repo: repo, number: target, merged: false}
    end

    def comment_event(comment)
      {
        "type" => "comment",
        "author" => comment.dig("user", "login"),
        "body" => comment["body"].to_s
      }
    end

    def authorized_human?(login)
      config.authorized?(login) && !bot?(login)
    end

    def ignored?(text)
      Triggers.ignore?(text, config.ignore_word)
    end

    def cleanup?(text)
      Triggers.cleanup?(text, config.cleanup_word)
    end

    def bot?(login)
      login.to_s.downcase == gh.login.downcase
    end
  end
end
