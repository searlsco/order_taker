require "tldr"
require "order_taker"
require "tmpdir"

# A hand-rolled gh double: canned responses keyed by API path (query string
# stripped), and a log of posted comments.
class FakeGh
  attr_reader :posted

  def initialize(login: "bitsly", responses: {})
    @login = login
    @responses = responses
    @posted = []
  end

  def api(path, paginate: false)
    @responses.fetch(path.split("?").first, [])
  end

  def login
    @login
  end

  def post_comment(repo, number, body)
    @posted << {repo: repo, number: number, body: body}
  end
end

CONFIG_JSON = {
  "authorized_authors" => ["searls", "bitsly"],
  "go_word" => "roadhouse",
  "default_agent" => "claude",
  "repos" => {
    "searls/example" => {"path" => "/tmp/example"}
  }
}.freeze

def build_config(overrides = {})
  OrderTaker::Config.new(CONFIG_JSON.merge(overrides))
end

def build_state(dir)
  OrderTaker::State.new(File.join(dir, "state.json"))
end

NULL_LOG = ->(message) {}
