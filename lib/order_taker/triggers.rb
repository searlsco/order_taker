module OrderTaker
  # Parses human signals out of issue/comment text: agent hashtags and the go word.
  module Triggers
    def self.agent_for(text, default:)
      case text.to_s.downcase
      when /#claude\b/ then "claude"
      when /#codex\b/ then "codex"
      else default
      end
    end

    def self.go?(text, go_word)
      /\b#{Regexp.escape(go_word)}\b/i.match?(text.to_s)
    end

    def self.ignore?(text, ignore_word)
      return false unless ignore_word
      /\b#{Regexp.escape(ignore_word)}\b/i.match?(text.to_s)
    end
  end
end
