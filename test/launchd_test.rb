class LaunchdTest < TLDR
  def test_plist_sets_a_utf_8_locale
    plist = OrderTaker::Launchd.plist("/tmp/order_taker")

    assert_match %r{<key>LANG</key>\s*<string>en_US\.UTF-8</string>}, plist
  end

  def test_restart_kickstarts_the_user_launch_agent
    command = nil
    fake_system = ->(*args) {
      command = args
      true
    }

    OrderTaker::Launchd.restart(command: fake_system)

    assert_equal ["launchctl", "kickstart", "-k", "gui/#{Process.uid}/co.searls.order_taker"], command
  end

  def test_restart_raises_when_kickstart_fails
    assert_raises(OrderTaker::Error) { OrderTaker::Launchd.restart(command: ->(*) { false }) }
  end
end
