class LocalResumeTest < TLDR
  def setup
    @dir = Dir.mktmpdir
    @lip_gloss = File.join(@dir, "lip_gloss")
    @worktree = File.join(@dir, "worktree")
    FileUtils.mkdir_p([@lip_gloss, @worktree])
    @config = build_config("repos" => {
      "searls/lip_gloss" => {
        "path" => @lip_gloss,
        "agent_args" => {"claude" => ["--model", "opus"], "codex" => ["--model", "gpt-5"]}
      },
      "other/example" => {"path" => File.join(@dir, "example")}
    })
    @state = build_state(@dir)
    @launches = []
    @launcher = ->(argv, cwd:) {
      @launches << {argv: argv, cwd: cwd}
      true
    }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_resumes_issue_in_its_worktree
    record = @state.ensure_issue("searls/lip_gloss", 35, agent: "claude")
    record.merge!("session_started" => true, "session_id" => "abc-123",
      "phase" => "work", "worktree" => @worktree)

    result = resume_session("searls/lip_gloss#35")

    assert result
    assert_equal [{
      argv: ["claude", "--dangerously-skip-permissions", "--resume", "abc-123", "--model", "opus"],
      cwd: @worktree
    }], @launches
  end

  def test_resolves_unique_repo_name_and_pull_number
    record = @state.ensure_issue("searls/lip_gloss", 35, agent: "codex")
    record.merge!("session_started" => true, "session_id" => "thread-1", "pr_number" => 41)

    resume_session("lip_gloss#41")

    assert_equal [{
      argv: ["codex", "resume", "thread-1", "--dangerously-bypass-approvals-and-sandbox", "--model", "gpt-5"],
      cwd: @lip_gloss
    }], @launches
  end

  def test_rejects_ambiguous_repo_name
    config = build_config("repos" => {
      "searls/example" => {"path" => @lip_gloss},
      "other/example" => {"path" => @worktree}
    })

    error = assert_raises(OrderTaker::LocalResumeError) {
      OrderTaker::LocalResume.new(config: config, state: @state, launcher: @launcher).call("example#35")
    }

    assert_match(/matches multiple watched repositories/, error.message)
  end

  def test_rejects_unknown_session
    error = assert_raises(OrderTaker::LocalResumeError) {
      resume_session("lip_gloss#99")
    }

    assert_match(/No order_taker session/, error.message)
  end

  def test_rejects_session_that_has_not_started
    @state.ensure_issue("searls/lip_gloss", 35, agent: "claude")

    error = assert_raises(OrderTaker::LocalResumeError) {
      resume_session("lip_gloss#35")
    }

    assert_match(/has not started/, error.message)
  end

  def test_rejects_missing_worktree
    record = @state.ensure_issue("searls/lip_gloss", 35, agent: "claude")
    record.merge!("session_started" => true, "session_id" => "abc-123",
      "phase" => "work", "worktree" => File.join(@dir, "missing"))

    error = assert_raises(OrderTaker::LocalResumeError) {
      resume_session("lip_gloss#35")
    }

    assert_match(/worktree is missing/, error.message)
  end

  def test_holds_session_lock_while_agent_is_running
    record = @state.ensure_issue("searls/lip_gloss", 35, agent: "claude")
    record.merge!("session_started" => true, "session_id" => "abc-123")
    competing_lock = :not_checked
    launcher = ->(_argv, cwd:) {
      competing_lock = OrderTaker::SessionLock.try_acquire(
        "searls/lip_gloss#35", state_path: @state.path)
      true
    }

    OrderTaker::LocalResume.new(config: @config, state: @state, launcher: launcher).call("lip_gloss#35")

    assert_nil competing_lock
    available_afterward = OrderTaker::SessionLock.try_acquire(
      "searls/lip_gloss#35", state_path: @state.path)
    refute_nil available_afterward
    available_afterward.close
  end

  private

  def resume_session(reference)
    OrderTaker::LocalResume.new(config: @config, state: @state, launcher: @launcher).call(reference)
  end
end
