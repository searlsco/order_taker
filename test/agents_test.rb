class AgentsTest < TLDR
  def test_claude_first_run_mints_session_id
    record = {"session_id" => "abc-123", "session_started" => nil}

    argv = OrderTaker::Agents::Claude.command(prompt: "hi", record: record)

    assert_equal ["claude", "-p", "--dangerously-skip-permissions", "--session-id", "abc-123", "hi"], argv
  end

  def test_claude_resume_with_worktree_and_extra_args
    record = {"session_id" => "abc-123", "session_started" => true}

    argv = OrderTaker::Agents::Claude.command(prompt: "hi", record: record, worktree: "/wt", extra_args: ["--model", "opus"])

    assert_equal ["claude", "-p", "--dangerously-skip-permissions", "--resume", "abc-123", "--add-dir", "/wt", "--model", "opus", "hi"], argv
  end

  def test_claude_extract_uses_stdout
    result = OrderTaker::Runner::Result.new(stdout: "the plan\n", stderr: "", exit_status: 0, timed_out: false)

    extracted = OrderTaker::Agents::Claude.extract(result, {"session_id" => "abc-123"})

    assert_equal "the plan", extracted["message"]
    assert_equal "abc-123", extracted["session_id"]
  end

  def test_codex_first_run_and_resume
    first = OrderTaker::Agents::Codex.command(prompt: "hi", record: {"session_started" => nil}, out_file: "/o.txt")
    resume = OrderTaker::Agents::Codex.command(prompt: "hi", record: {"session_started" => true, "session_id" => "t-1"}, out_file: "/o.txt")

    assert_equal ["codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--json", "-o", "/o.txt", "hi"], first
    assert_equal ["codex", "exec", "resume", "t-1", "--dangerously-bypass-approvals-and-sandbox", "--json", "-o", "/o.txt", "hi"], resume
  end

  def test_codex_extract_parses_thread_id_and_reads_message_file
    Dir.mktmpdir do |dir|
      out_file = File.join(dir, "last.txt")
      File.write(out_file, "final answer\n")
      stdout = <<~JSONL
        {"type":"thread.started","thread_id":"0199a213-81b0-7643"}
        not json at all
        {"type":"turn.completed"}
      JSONL
      result = OrderTaker::Runner::Result.new(stdout: stdout, stderr: "", exit_status: 0, timed_out: false)

      extracted = OrderTaker::Agents::Codex.extract(result, {"session_id" => nil}, out_file: out_file)

      assert_equal "final answer", extracted["message"]
      assert_equal "0199a213-81b0-7643", extracted["session_id"]
    end
  end

  def test_codex_extract_keeps_known_session_id
    result = OrderTaker::Runner::Result.new(stdout: "", stderr: "", exit_status: 0, timed_out: false)

    extracted = OrderTaker::Agents::Codex.extract(result, {"session_id" => "t-1"}, out_file: "/nonexistent")

    assert_equal "t-1", extracted["session_id"]
    assert_equal "", extracted["message"]
  end

  def test_unknown_agent_raises
    assert_raises(OrderTaker::Error) { OrderTaker::Agents.for("gemini") }
  end
end
