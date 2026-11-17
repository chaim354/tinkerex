require "open3"

module Maker
  module Previews
    # ONE EXTERNAL PROGRAM RUN UNDER A WALL-CLOCK LIMIT: its stdout, its stderr and its exit status,
    # or the caller's own error once the limit has passed. Moved here unchanged from
    # Maker::Previews::Gerber, its only user until 2026-11-16, when the rasteriser gained the same
    # limit for the one input no cap has measured (SvgRasterizer.to_png's `timeout:`).
    #
    # WHO RUNS UNDER IT, AND WHY NOT EVERY RENDERER. resvg on a user's own SVG, pdfium, f3d and
    # stl-thumbnailer are each handed ONE file whose size the job has already capped at
    # MAX_PREVIEW_BYTES, and they run with no limit; whether they get one waits on timings from a
    # real library. The Gerber pipeline is the exception at BOTH of its steps. node is handed a
    # DECOMPRESSED, USER-SUPPLIED GEOMETRY BUDGET: a zip is bounded at 32 MB compressed and up to
    # GerberZip::MAX_EXTRACTED_BYTES (64 MB) of layers inflate out of it, and tracespace's cost is
    # in the plotted geometry rather than the byte count. resvg is then handed node's OUTPUT, an SVG
    # built from that geometry, which is not a file the job capped either. Measured in review: one
    # hand-built archive held a Solid Queue worker for 104 s before the OOM killer ended node.
    # Without a limit, a program that hangs, or merely grinds, wedges that worker INDEFINITELY, and
    # the workers serve every queue (config/queue.yml: three threads on `*`), so three bad files
    # stop every job in the app. A kill is the honest answer: the render is retried as `failed`,
    # not lost.
    #
    # `Open3.popen3` and not `capture3`, and STDOUT/STDERR ARE DRAINED IN THEIR OWN THREADS.
    # A board's SVG is several MB, far past a pipe buffer, so a single-threaded "wait then read"
    # deadlocks: the child blocks writing stdout while we block on `join`, and the timeout then
    # fires on a render that was working. `join(timeout)` answers nil exactly when the child is
    # still running, which is the signal — never an elapsed-time comparison of our own.
    #
    # KILL, NOT TERM, AND THE WHOLE PROCESS GROUP (`pgroup: true`, then a signal to `-pid`). Two
    # reasons, and the second is the one that is easy to miss: these subprocesses have no cleanup
    # worth running and a wedged one may ignore TERM entirely; and a GRANDCHILD INHERITS THE
    # STDOUT PIPE, so killing the direct child alone leaves the write end open and the reader
    # thread below blocks until that orphan exits — the timeout would then hand back exactly the
    # hang it exists to end. `Errno::ESRCH` is the benign race where the group was already gone
    # between the join and the signal. The reap (`wait_thr.join`) and the two reader joins run
    # before the raise so nothing is left behind: no zombie, no thread reading a dead pipe.
    module Subprocess
      module_function

      # `timeout` is in seconds. `error` is the class raised when it passes and `name` is what the
      # message calls the program: "tracespace timed out after 60s". A program that cannot be
      # started raises Errno::ENOENT / Errno::EACCES as it always did; that is the caller's to map.
      def capture(*cmd, timeout:, error:, name:)
        Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_thread = Thread.new { stdout.read }
          err_thread = Thread.new { stderr.read }
          unless wait_thr.join(timeout)
            begin
              Process.kill("KILL", -wait_thr.pid)
            rescue Errno::ESRCH
              nil
            end
            wait_thr.join
            out_thread.join
            err_thread.join
            raise error, "#{name} timed out after #{timeout}s"
          end
          [ out_thread.value, err_thread.value, wait_thr.value ]
        end
      end
    end
  end
end
