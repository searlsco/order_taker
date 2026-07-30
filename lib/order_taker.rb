module OrderTaker
  Error = Class.new(StandardError)
  ConfigError = Class.new(Error)
end

require "order_taker/version"
require "order_taker/config"
require "order_taker/state"
require "order_taker/gh"
require "order_taker/session_key"
require "order_taker/triggers"
require "order_taker/prompts"
require "order_taker/agents"
require "order_taker/runner"
require "order_taker/worktrees"
require "order_taker/gatherer"
require "order_taker/daemon"
require "order_taker/launchd"
require "order_taker/cli"
