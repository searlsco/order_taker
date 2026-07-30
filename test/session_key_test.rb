class SessionKeyTest < TLDR
  def test_uuid_is_deterministic_and_well_formed
    a = OrderTaker::SessionKey.uuid("searls/example", 5)
    b = OrderTaker::SessionKey.uuid("searls/example", 5)

    assert_equal a, b
    assert_match(/\A\h{8}-\h{4}-5\h{3}-[89ab]\h{3}-\h{12}\z/, a)
  end

  def test_uuid_differs_by_thread
    refute_equal OrderTaker::SessionKey.uuid("searls/example", 5),
      OrderTaker::SessionKey.uuid("searls/example", 6)
    refute_equal OrderTaker::SessionKey.uuid("searls/example", 5),
      OrderTaker::SessionKey.uuid("searls/other", 5)
  end
end
