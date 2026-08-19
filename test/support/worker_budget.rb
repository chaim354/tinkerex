# How many parallel workers a BROWSER-BOUND suite may have.
#
# WHY THIS IS NOT `:number_of_processors`. That is a CPU heuristic — it answers "how many things can
# compute at once" — and a system-test worker does not compute. It carries a whole headless Chrome.
# The binding constraint is RAM, and on this box the CPU answer overruns it. Measured mid-run,
# 10-core machine with 24 GB:
#
#     workers=10   Chrome RSS 19.7 GB   free 0.1 GB
#     workers=6    Chrome RSS 14.5 GB   free 1.6 GB
#
# Ten Chromes take 19.7 GB of 24 GB and leave 0.1 GB free, so anything else wanting memory pushes
# the machine into swap and every Capybara wait becomes a coin flip. The failures that follow are
# WAIT TIMEOUTS, never crashes — `Unable to find css ".filechooser-row"`, or `expected "Saved." but
# found "Saving…"` — which is exactly what a swapping machine looks like from inside a browser test,
# and exactly why they read as flakes rather than as a resource problem.
#
# THE EXTRA WORKERS BUY NOTHING. Solo wall time is flat from 4 to 10 workers (~19–22 s for 102
# tests), so the six workers above the cap cost 5 GB and save no time. Under the condition that
# actually breaks it — a second browser suite running concurrently — 2 of 3 trials at ten workers
# failed (once 6 failures + 1 error) against 0 of 5 at six or four.
#
# THREE PROBES RULED OUT THE OBVIOUS ANSWERS, and they are the reason this file talks about memory
# rather than time: CPU saturation (ten spinners, load average 60) does NOT reproduce it — 23.4 s,
# green. A concurrent 2381-run NON-browser suite does NOT reproduce it — 22.2 s, green. Only a
# concurrent BROWSER suite does, because only that doubles the Chrome footprint. Do not "fix" a
# recurrence here by raising `Capybara.default_max_wait_time`: that converts a fast red into a slow
# red and taxes every genuine failure with the new timeout.
#
# DERIVED, NOT A LITERAL. A flat `6` would be right for this laptop and wrong for the next machine —
# and `docs/DEPLOY.md`'s CI runner is a developer's own laptop today but need not stay one. The
# budget below adapts; the cap by processor count keeps a huge-RAM box from spawning more browsers
# than it has cores to drive them with.
module WorkerBudget
  # Bytes of RAM to reserve per browser worker. The marginal cost measured above is ~1.3 GB per
  # worker over a ~6.7 GB baseline; 4 GB is deliberately generous, because the budget has to hold
  # when a SECOND browser suite is running — a developer's local `bin/ci` beside a CI job on the
  # same machine, which is this repo's real configuration and the condition that produced the
  # original failures.
  BYTES_PER_BROWSER_WORKER = 4 * (1024**3)

  class << self
    # Never returns less than 1, never more than the processor count, and never raises: an
    # unreadable total falls back to the processor count, which is the behaviour this replaces.
    # Failing back to the OLD default rather than to the new cap is deliberate — a machine we
    # cannot measure should behave as it did before this file existed, not inherit a number
    # derived from a box it may look nothing like.
    def browser_workers
      cores = processor_count
      total = total_memory_bytes
      return cores if total.nil? || total.zero?

      [ [ total / BYTES_PER_BROWSER_WORKER, 1 ].max, cores ].min
    end

    def processor_count
      (Concurrent.available_processor_count || Concurrent.processor_count).floor
    rescue StandardError
      1
    end

    # macOS and Linux only, which is every machine this suite runs on. Anything else answers nil
    # and takes the fallback above.
    def total_memory_bytes
      case RbConfig::CONFIG["host_os"]
      when /darwin/i
        out = `sysctl -n hw.memsize 2>/dev/null`
        Integer(out.strip, exception: false)
      when /linux/i
        line = File.read("/proc/meminfo")[/^MemTotal:\s+(\d+) kB/, 1]
        line && line.to_i * 1024
      end
    rescue StandardError
      nil
    end
  end
end
