class LaunchdTest < TLDR
  def test_plist_sets_a_utf_8_locale
    plist = OrderTaker::Launchd.plist("/tmp/order_taker")

    assert_match %r{<key>LANG</key>\s*<string>en_US\.UTF-8</string>}, plist
  end
end
