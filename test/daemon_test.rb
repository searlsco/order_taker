class DaemonTest < TLDR
  REPO = "searls/example"

  class FakeRunner
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def run(argv, cwd:, timeout:)
      @calls << {argv: argv, cwd: cwd, timeout: timeout}
      @result
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @state = build_state(@dir)
    OrderTaker::Gatherer::CURSORS.each { |kind| @state.set_cursor(REPO, kind, "2026-01-01T00:00:00Z") }
    @gh = FakeGh.new
    @config = build_config("repos" => {REPO => {"path" => @dir}})
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def daemon(result)
    @runner = FakeRunner.new(result)
    OrderTaker::Daemon.new(config: @config, state: @state, gh: @gh, log: NULL_LOG, runner: @runner)
  end

  def tick_until_reaped(subject)
    subject.tick
    sleep 0.05
    subject.tick
  end

  def test_successful_plan_run_posts_comment_and_consumes_events
    record = @state.ensure_issue(REPO, 7, agent: "claude")
    record["session_id"] = "uuid-7"
    @state.append_events(REPO, 7, [{"type" => "issue_opened", "author" => "searls", "title" => "A bug", "body" => "fix it"}])
    subject = daemon(OrderTaker::Runner::Result.new(stdout: "here is my plan", stderr: "", exit_status: 0, timed_out: false))

    tick_until_reaped(subject)

    assert_equal [{repo: REPO, number: 7, body: "here is my plan"}], @gh.posted
    assert_empty record["pending_events"]
    assert record["session_started"]
    argv = @runner.calls.first[:argv]
    assert_equal ["claude", "-p", "--dangerously-skip-permissions", "--session-id", "uuid-7"], argv.first(5)
    assert_includes argv.last, "A bug"
  end

  def test_failed_run_posts_failure_comment_and_still_consumes_events
    record = @state.ensure_issue(REPO, 7, agent: "claude")
    record["session_id"] = "uuid-7"
    @state.append_events(REPO, 7, [{"type" => "comment", "author" => "searls", "body" => "hello?"}])
    subject = daemon(OrderTaker::Runner::Result.new(stdout: "", stderr: "boom\n", exit_status: 1, timed_out: false))

    tick_until_reaped(subject)

    assert_equal 1, @gh.posted.size
    assert_includes @gh.posted.first[:body], "exited 1"
    assert_includes @gh.posted.first[:body], "boom"
    assert_empty record["pending_events"]
    refute record["session_started"]
  end

  def test_wind_down_archives_and_clears_pending_events
    record = @state.ensure_issue(REPO, 7, agent: "claude")
    record.merge!(
      "phase" => "work",
      "branch" => "order-taker/issue-7",
      "pending_wind_down" => {"merged" => false},
      "pending_events" => [{"type" => "comment", "body" => "raced in"}]
    )
    subject = daemon(nil)

    subject.tick

    assert_equal "archived", record["phase"]
    assert_empty record["pending_events"]
    assert_nil record["pending_wind_down"]
    assert_empty @gh.posted
  end

  def test_concurrency_cap_limits_simultaneous_runs
    config = build_config("repos" => {REPO => {"path" => @dir}}, "max_concurrent_runs" => 1)
    (1..3).each do |number|
      record = @state.ensure_issue(REPO, number, agent: "claude")
      record["session_id"] = "uuid-#{number}"
      @state.append_events(REPO, number, [{"type" => "comment", "author" => "searls", "body" => "hi"}])
    end
    @runner = FakeRunner.new(OrderTaker::Runner::Result.new(stdout: "ok", stderr: "", exit_status: 0, timed_out: false))
    subject = OrderTaker::Daemon.new(config: config, state: @state, gh: @gh, log: NULL_LOG, runner: @runner)

    subject.tick
    sleep 0.05

    assert_equal 1, @runner.calls.size
  end

  def test_default_logger_is_shared_with_gatherer
    state = build_state(File.join(@dir, "fresh"))
    subject = OrderTaker::Daemon.new(config: @config, state: state, gh: @gh)

    subject.tick

    refute_nil state.cursor(REPO, "issues")
  end
end
