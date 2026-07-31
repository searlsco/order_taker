require "fileutils"

module OrderTaker
  # Prevents the daemon and a local terminal from resuming the same agent
  # session concurrently. The operating system releases the lock on exit.
  module SessionLock
    def self.try_acquire(key, state_path:)
      dir = File.join(File.dirname(state_path), "locks")
      FileUtils.mkdir_p(dir)
      file = File.open(File.join(dir, "#{key.tr("/#", "--")}.lock"), "w")
      return file if file.flock(File::LOCK_EX | File::LOCK_NB)

      file.close
      nil
    end
  end
end
