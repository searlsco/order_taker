class ConfigTest < TLDR
  def test_valid_config_with_defaults
    config = build_config

    assert_equal ["searls", "bitsly"], config.authorized_authors
    assert_equal "roadhouse", config.go_word
    assert_nil config.ignore_word
    assert_nil config.cleanup_word
    assert_equal "claude", config.default_agent
    assert_equal 60, config.poll_interval_seconds
    assert_equal 2, config.max_concurrent_runs
    assert_equal 3600, config.run_timeout_seconds
    assert_equal "/tmp/example", config.repo("searls/example").path
    assert_equal "claude", config.repo("searls/example").default_agent
  end

  def test_authorized_is_case_insensitive
    config = build_config

    assert config.authorized?("Searls")
    refute config.authorized?("stranger")
  end

  def test_repo_default_agent_override
    config = build_config("repos" => {
      "searls/example" => {"path" => "/tmp/example", "default_agent" => "codex"}
    })

    assert_equal "codex", config.repo("searls/example").default_agent
  end

  def test_missing_authorized_authors_raises
    error = assert_raises(OrderTaker::ConfigError) {
      OrderTaker::Config.new(CONFIG_JSON.except("authorized_authors"))
    }
    assert_match(/authorized_authors/, error.message)
  end

  def test_blank_go_word_raises
    assert_raises(OrderTaker::ConfigError) { build_config("go_word" => "  ") }
  end

  def test_ignore_word_is_optional_and_case_insensitive
    config = build_config("ignore_word" => "  Hush  ")

    assert_equal "hush", config.ignore_word
  end

  def test_blank_ignore_word_raises
    assert_raises(OrderTaker::ConfigError) { build_config("ignore_word" => "  ") }
  end

  def test_cleanup_word_is_optional_and_case_insensitive
    config = build_config("cleanup_word" => "  Cleanup  ")

    assert_equal "cleanup", config.cleanup_word
  end

  def test_blank_cleanup_word_raises
    assert_raises(OrderTaker::ConfigError) { build_config("cleanup_word" => "  ") }
  end

  def test_bogus_agent_raises
    assert_raises(OrderTaker::ConfigError) { build_config("default_agent" => "gemini") }
  end

  def test_repo_without_path_raises
    assert_raises(OrderTaker::ConfigError) { build_config("repos" => {"searls/example" => {}}) }
  end

  def test_repo_path_is_expanded
    config = build_config("repos" => {"searls/example" => {"path" => "~/code/example"}})

    assert_equal File.join(Dir.home, "code", "example"), config.repo("searls/example").path
  end

  def test_example_config_parses_and_validates
    OrderTaker::Config.new(JSON.parse(OrderTaker::Config::EXAMPLE))
  end

  def test_load_reads_utf_8_config_when_default_external_encoding_is_us_ascii
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.binwrite(path, JSON.generate(CONFIG_JSON.merge("go_word" => "道")))
      original_encoding = Encoding.default_external
      original_verbose = $VERBOSE

      begin
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII

        assert_equal "道", OrderTaker::Config.load(path).go_word
      ensure
        Encoding.default_external = original_encoding
        $VERBOSE = original_verbose
      end
    end
  end
end
