class RunnerTest < TLDR
  def test_captures_stdout_and_exit_status
    result = OrderTaker::Runner.run(["sh", "-c", "echo hello; echo oops >&2"], cwd: Dir.pwd, timeout: 10)

    assert result.success?
    assert_equal "hello\n", result.stdout
    assert_equal "oops\n", result.stderr
  end

  def test_reports_failure_exit_status
    result = OrderTaker::Runner.run(["sh", "-c", "exit 3"], cwd: Dir.pwd, timeout: 10)

    refute result.success?
    assert_equal 3, result.exit_status
  end

  def test_kills_on_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = OrderTaker::Runner.run(["sleep", "30"], cwd: Dir.pwd, timeout: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    refute result.success?
    assert elapsed < 15, "expected timeout kill to be prompt, took #{elapsed}s"
  end
end
