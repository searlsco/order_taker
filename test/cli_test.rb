class CliTest < TLDR
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
