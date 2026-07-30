class GathererTest < TLDR
  REPO = "searls/example"
  OLD = "2026-01-01T00:00:00Z"

  def setup
    @dir = Dir.mktmpdir
    @state = build_state(@dir)
    OrderTaker::Gatherer::CURSORS.each { |kind| @state.set_cursor(REPO, kind, OLD) }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def gatherer(responses = {})
    @gh = FakeGh.new(responses: responses)
    OrderTaker::Gatherer.new(config: build_config, state: @state, gh: @gh, log: NULL_LOG)
  end

  def issue_json(number, title: "A bug", body: "fix it", author: "searls", state: "open", created_at: "2026-02-01T00:00:00Z", closed_at: nil, pull_request: nil)
    {
      "number" => number, "title" => title, "body" => body,
      "user" => {"login" => author}, "state" => state,
      "created_at" => created_at, "updated_at" => closed_at || created_at,
      "closed_at" => closed_at, "pull_request" => pull_request
    }.compact
  end

  def comment_json(number, body:, author: "searls", id: 1, created_at: "2026-02-01T00:00:00Z")
    {
      "id" => id, "body" => body, "user" => {"login" => author},
      "created_at" => created_at, "issue_url" => "https://api.github.com/repos/#{REPO}/issues/#{number}"
    }
  end

  def test_first_poll_only_initializes_cursors
    fresh_state = build_state(File.join(@dir, "fresh"))
    subject = OrderTaker::Gatherer.new(config: build_config, state: fresh_state, gh: FakeGh.new, log: NULL_LOG)

    assert_equal [], subject.poll
    refute_nil fresh_state.cursor(REPO, "issues")
    assert_empty fresh_state.issues(REPO)
  end

  def test_new_issue_opens_session_with_claude_uuid
    subject = gatherer("repos/#{REPO}/issues" => [issue_json(7)])

    subject.poll

    record = @state.issue(REPO, 7)
    assert_equal "claude", record["agent"]
    assert_equal OrderTaker::SessionKey.uuid(REPO, 7), record["session_id"]
    assert_equal [{"type" => "issue_opened", "author" => "searls", "title" => "A bug", "body" => "fix it"}],
      record["pending_events"]
  end

  def test_hashtag_selects_codex
    subject = gatherer("repos/#{REPO}/issues" => [issue_json(7, title: "A bug #codex")])

    subject.poll

    record = @state.issue(REPO, 7)
    assert_equal "codex", record["agent"]
    assert_nil record["session_id"]
  end

  def test_unauthorized_and_bot_issues_ignored
    subject = gatherer("repos/#{REPO}/issues" => [
      issue_json(7, author: "stranger"),
      issue_json(8, author: "bitsly")
    ])

    subject.poll

    assert_empty @state.issues(REPO)
  end

  def test_comment_on_known_issue_appends_event
    @state.ensure_issue(REPO, 7, agent: "claude")
    subject = gatherer("repos/#{REPO}/issues/comments" => [comment_json(7, body: "more detail")])

    subject.poll

    assert_equal ["more detail"], @state.issue(REPO, 7)["pending_events"].map { |event| event["body"] }
  end

  def test_bot_and_stale_comments_ignored
    @state.ensure_issue(REPO, 7, agent: "claude")
    subject = gatherer("repos/#{REPO}/issues/comments" => [
      comment_json(7, body: "from the bot", author: "bitsly"),
      comment_json(7, body: "edited old comment", created_at: "2025-12-01T00:00:00Z")
    ])

    subject.poll

    assert_empty @state.issue(REPO, 7)["pending_events"]
  end

  def test_comment_on_unknown_thread_enrolls_with_full_history
    subject = gatherer(
      "repos/#{REPO}/issues/comments" => [comment_json(7, body: "let's do this one", id: 30)],
      "repos/#{REPO}/issues/7" => issue_json(7, author: "stranger", created_at: "2025-06-01T00:00:00Z"),
      "repos/#{REPO}/issues/7/comments" => [
        comment_json(7, body: "old bot reply", author: "bitsly", id: 10, created_at: "2025-06-02T00:00:00Z"),
        comment_json(7, body: "prior human note", id: 20, created_at: "2025-06-03T00:00:00Z"),
        comment_json(7, body: "let's do this one", id: 30)
      ]
    )

    subject.poll

    events = @state.issue(REPO, 7)["pending_events"]
    assert_equal ["issue_opened", "comment", "comment"], events.map { |event| event["type"] }
    assert_equal ["prior human note", "let's do this one"], events.last(2).map { |event| event["body"] }
  end

  def test_merged_pr_winds_down_originating_issue
    @state.ensure_issue(REPO, 7, agent: "claude")["pr_number"] = 9
    subject = gatherer("repos/#{REPO}/issues" => [
      issue_json(9, state: "closed", closed_at: "2026-02-01T00:00:00Z", pull_request: {"merged_at" => "2026-02-01T00:00:00Z"})
    ])

    wind_downs = subject.poll

    assert_equal [{repo: REPO, number: 7, merged: true}], wind_downs
  end

  def test_closed_issue_winds_down_its_own_session
    @state.ensure_issue(REPO, 7, agent: "claude")
    subject = gatherer("repos/#{REPO}/issues" => [
      issue_json(7, state: "closed", closed_at: "2026-02-01T00:00:00Z")
    ])

    assert_equal [{repo: REPO, number: 7, merged: false}], subject.poll
  end

  def test_review_comment_routes_to_originating_issue
    @state.ensure_issue(REPO, 7, agent: "claude")["pr_number"] = 9
    subject = gatherer("repos/#{REPO}/pulls/comments" => [{
      "body" => "rename this", "path" => "lib/widget.rb", "user" => {"login" => "searls"},
      "created_at" => "2026-02-01T00:00:00Z",
      "pull_request_url" => "https://api.github.com/repos/#{REPO}/pulls/9"
    }])

    subject.poll

    events = @state.issue(REPO, 7)["pending_events"]
    assert_equal [{"type" => "review_comment", "author" => "searls", "path" => "lib/widget.rb", "body" => "rename this"}], events
  end

  def test_review_summaries_polled_for_sessions_with_prs
    @state.ensure_issue(REPO, 7, agent: "claude")["pr_number"] = 9
    subject = gatherer("repos/#{REPO}/pulls/9/reviews" => [
      {"state" => "CHANGES_REQUESTED", "body" => "close, but", "user" => {"login" => "searls"}, "submitted_at" => "2026-02-01T00:00:00Z"},
      {"state" => "COMMENTED", "body" => "", "user" => {"login" => "searls"}, "submitted_at" => "2026-02-01T00:00:01Z"}
    ])

    subject.poll

    events = @state.issue(REPO, 7)["pending_events"]
    assert_equal ["close, but"], events.map { |event| event["body"] }
  end

  def test_comment_revives_archived_session_to_plan_phase
    record = @state.ensure_issue(REPO, 7, agent: "claude")
    record.merge!("phase" => "archived", "worktree" => "/old", "branch" => "order-taker/issue-7")
    subject = gatherer("repos/#{REPO}/issues/comments" => [comment_json(7, body: "one more thing")])

    subject.poll

    assert_equal "plan", record["phase"]
    assert_nil record["worktree"]
    assert_nil record["branch"]
    assert_equal ["one more thing"], record["pending_events"].map { |event| event["body"] }
  end

  def test_cursors_advance_past_seen_activity
    subject = gatherer(
      "repos/#{REPO}/issues" => [issue_json(7, created_at: "2026-02-01T00:00:00Z")],
      "repos/#{REPO}/issues/comments" => []
    )

    subject.poll

    assert_equal "2026-02-01T00:00:00Z", @state.cursor(REPO, "issues")
    assert_equal OLD, @state.cursor(REPO, "comments")
  end
end
