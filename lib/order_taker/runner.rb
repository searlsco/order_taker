module OrderTaker
  # Spawns an agent process with a hard timeout, killing its whole process
  # group if it exceeds it (unattended runs must never hang forever).
  module Runner
    Result = Struct.new(:stdout, :stderr, :exit_status, :timed_out, keyword_init: true) do
      def success?
        !timed_out && exit_status == 0
      end
    end

    def self.run(argv, cwd:, timeout:, stdout_path: nil, stderr_path: nil)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(*argv, chdir: cwd, in: :close, out: out_w, err: err_w, pgroup: true)
      out_w.close
      err_w.close
      out_thread = Thread.new { capture(out_r, stdout_path) }
      err_thread = Thread.new { capture(err_r, stderr_path) }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      status = nil
      timed_out = false
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        break if status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          timed_out = true
          kill_group(pid)
          _, status = Process.waitpid2(pid)
          break
        end
        sleep 0.5
      end

      Result.new(
        stdout: out_thread.value,
        stderr: err_thread.value,
        exit_status: status.exitstatus || status.termsig && 128 + status.termsig || 1,
        timed_out: timed_out
      )
    ensure
      [out_r, err_r].each { |io| io.close unless io.closed? }
    end

    def self.capture(io, path)
      output = +""
      file = File.open(path, "wb") if path
      while (chunk = io.read(16 * 1024))
        output << chunk
        file&.write(chunk)
        file&.flush
      end
      output
    ensure
      file&.close
    end

    def self.kill_group(pid)
      Process.kill("TERM", -pid)
      10.times do
        sleep 0.5
        Process.kill(0, -pid)
      end
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM # group already gone (macOS reports EPERM for zombie groups)
    end
  end
end
