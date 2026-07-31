class RunnerTest < TLDR
  def test_captures_stdout_and_exit_status
    result = OrderTaker::Runner.run(["sh", "-c", "echo hello; echo oops >&2"], cwd: Dir.pwd, timeout: 10)

    assert result.success?
    assert_equal "hello\n", result.stdout
    assert_equal "oops\n", result.stderr
  end

  def test_streams_stdout_and_stderr_to_files
    Dir.mktmpdir do |dir|
      stdout_path = File.join(dir, "stdout.log")
      stderr_path = File.join(dir, "stderr.log")

      result = OrderTaker::Runner.run(
        ["sh", "-c", "echo hello; echo oops >&2"],
        cwd: Dir.pwd,
        timeout: 10,
        stdout_path: stdout_path,
        stderr_path: stderr_path
      )

      assert result.success?
      assert_equal "hello\n", File.read(stdout_path)
      assert_equal "oops\n", File.read(stderr_path)
    end
  end

  def test_reports_failure_exit_status
    result = OrderTaker::Runner.run(["sh", "-c", "exit 3"], cwd: Dir.pwd, timeout: 10)

    refute result.success?
    assert_equal 3, result.exit_status
  end

  def test_kills_on_timeout
    Dir.mktmpdir do |dir|
      stdout_path = File.join(dir, "stdout.log")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = OrderTaker::Runner.run(
        ["sh", "-c", "echo before-timeout; sleep 30"],
        cwd: Dir.pwd,
        timeout: 1,
        stdout_path: stdout_path
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert result.timed_out
      refute result.success?
      assert_equal "before-timeout\n", File.read(stdout_path)
      assert elapsed < 15, "expected timeout kill to be prompt, took #{elapsed}s"
    end
  end
end
