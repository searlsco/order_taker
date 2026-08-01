class CliTest < TLDR
  def test_restart_validates_config_and_restarts_launch_agent
    config = Class.new do
      attr_reader :loaded
      def load = @loaded = true
    end.new
    launchd = Class.new do
      attr_reader :restarted
      def restart
        @restarted = true
        "co.searls.order_taker"
      end
    end.new

    stdout = StringIO.new
    stderr = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    begin
      assert_equal 0, OrderTaker::Cli.new(config: config, launchd: launchd).call(["restart"])
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end

    assert config.loaded
    assert launchd.restarted
    assert_match(/Restarted co\.searls\.order_taker/, stdout.string)
    assert_empty stderr.string
  end

  def test_resume_requires_a_reference
    stderr = StringIO.new
    original_stderr = $stderr
    $stderr = stderr

    result = OrderTaker::Cli.new.call(["resume"])

    assert_equal 1, result
    assert_match(/Usage: order_taker resume/, stderr.string)
  ensure
    $stderr = original_stderr
  end
end
