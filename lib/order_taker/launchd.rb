require "fileutils"
require "rbconfig"

module OrderTaker
  # Installs a LaunchAgent that keeps `order_taker run` alive while logged in.
  # The Mac must be awake (lid open); display sleep is fine.
  module Launchd
    LABEL = "co.searls.order_taker"
    PLIST_PATH = File.join(Dir.home, "Library", "LaunchAgents", "#{LABEL}.plist")
    LOG_DIR = File.join(State::DIR, "log")

    def self.install(bin_path)
      FileUtils.mkdir_p(LOG_DIR)
      FileUtils.mkdir_p(File.dirname(PLIST_PATH))
      File.write(PLIST_PATH, plist(bin_path))
      system("launchctl", "unload", PLIST_PATH, err: File::NULL)
      system("launchctl", "load", "-w", PLIST_PATH) or raise Error, "launchctl load failed"
      PLIST_PATH
    end

    def self.uninstall
      system("launchctl", "unload", PLIST_PATH, err: File::NULL) if File.exist?(PLIST_PATH)
      FileUtils.rm_f(PLIST_PATH)
      PLIST_PATH
    end

    def self.restart(command: method(:system))
      command.call("launchctl", "kickstart", "-k", "gui/#{Process.uid}/#{LABEL}") or
        raise Error, "launchctl restart failed; run `order_taker install` first"
      LABEL
    end

    # Pins the current Ruby, PATH, and locale so launchd's minimal environment
    # can still find commands and process their UTF-8 output.
    def self.plist(bin_path)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{LABEL}</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{RbConfig.ruby}</string>
            <string>#{bin_path}</string>
            <string>run</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>LANG</key>
            <string>en_US.UTF-8</string>
            <key>PATH</key>
            <string>#{ENV["PATH"]}</string>
          </dict>
          <key>KeepAlive</key>
          <true/>
          <key>RunAtLoad</key>
          <true/>
          <key>ProcessType</key>
          <string>Background</string>
          <key>StandardOutPath</key>
          <string>#{File.join(LOG_DIR, "daemon.log")}</string>
          <key>StandardErrorPath</key>
          <string>#{File.join(LOG_DIR, "daemon.error.log")}</string>
        </dict>
        </plist>
      XML
    end
  end
end
