class StateTest < TLDR
  def test_round_trips_to_disk
    Dir.mktmpdir do |dir|
      state = build_state(dir)
      state.set_cursor("searls/example", "issues", "2026-07-30T00:00:00Z")
      state.ensure_issue("searls/example", 5, agent: "claude")
      state.save

      reloaded = build_state(dir)
      assert_equal "2026-07-30T00:00:00Z", reloaded.cursor("searls/example", "issues")
      assert_equal "plan", reloaded.issue("searls/example", 5)["phase"]
    end
  end

  def test_ensure_issue_is_idempotent
    Dir.mktmpdir do |dir|
      state = build_state(dir)
      record = state.ensure_issue("searls/example", 5, agent: "claude")
      record["phase"] = "work"

      assert_equal "work", state.ensure_issue("searls/example", 5, agent: "codex")["phase"]
      assert_equal "claude", state.issue("searls/example", 5)["agent"]
    end
  end

  def test_consume_events_removes_only_the_batch
    Dir.mktmpdir do |dir|
      state = build_state(dir)
      state.ensure_issue("searls/example", 5, agent: "claude")
      state.append_events("searls/example", 5, [{"type" => "comment", "body" => "one"}, {"type" => "comment", "body" => "two"}])
      state.append_events("searls/example", 5, [{"type" => "comment", "body" => "three"}])

      state.consume_events("searls/example", 5, 2)

      assert_equal ["three"], state.issue("searls/example", 5)["pending_events"].map { |event| event["body"] }
    end
  end

  def test_issue_for_pr_finds_originating_issue
    Dir.mktmpdir do |dir|
      state = build_state(dir)
      state.ensure_issue("searls/example", 5, agent: "claude")["pr_number"] = 9

      number, record = state.issue_for_pr("searls/example", 9)
      assert_equal "5", number
      assert_equal 9, record["pr_number"]
      assert_nil state.issue_for_pr("searls/example", 10)
    end
  end
end
