class TriggersTest < TLDR
  def test_agent_hashtags
    assert_equal "codex", OrderTaker::Triggers.agent_for("Fix crash #codex", default: "claude")
    assert_equal "claude", OrderTaker::Triggers.agent_for("Fix crash #claude please", default: "codex")
    assert_equal "claude", OrderTaker::Triggers.agent_for("Fix crash", default: "claude")
    assert_equal "codex", OrderTaker::Triggers.agent_for("Fix crash #CODEX", default: "claude")
  end

  def test_go_word_matches_whole_word_case_insensitively
    assert OrderTaker::Triggers.go?("Roadhouse", "roadhouse")
    assert OrderTaker::Triggers.go?("ok, roadhouse! also please add tests", "roadhouse")
    refute OrderTaker::Triggers.go?("the roadhouses of america", "roadhouse")
    refute OrderTaker::Triggers.go?("sounds good, keep planning", "roadhouse")
    refute OrderTaker::Triggers.go?(nil, "roadhouse")
  end
end
