require "digest"

module OrderTaker
  # Deterministic session identity per thread ("owner/name#123"), so no IDs
  # need capturing from claude (codex reports its own thread id at runtime).
  module SessionKey
    NAMESPACE = "order_taker.searls.co"

    # RFC 4122 version-5 (SHA-1, name-based) UUID
    def self.uuid(repo, number)
      digest = Digest::SHA1.digest("#{NAMESPACE}/#{repo}##{number}")
      bytes = digest.bytes.first(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x50
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.pack("C*").unpack1("H*")
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    def self.thread_key(repo, number)
      "#{repo}##{number}"
    end
  end
end
