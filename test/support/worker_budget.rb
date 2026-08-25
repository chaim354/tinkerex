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

  # WHERE A RUNNING BROWSER SUITE LEAVES ITS MARK. Resolved from THIS FILE rather than from
  # Rails.root: worker_budget_test.rb requires this file directly, with no Rails loaded.
  #
  # DEFINED OUT HERE, NOT INSIDE `class << self` — a constant assigned in a singleton-class body
  # belongs to the SINGLETON, so `WorkerBudget::PIDFILE_DIR` raises NameError while
  # `WorkerBudget.singleton_class::PIDFILE_DIR` resolves. That is exactly how this shipped for its
  # first five minutes, and the test that names the constant is what caught it.
  PIDFILE_DIR = File.expand_path("../../tmp/browser-suites", __dir__)


  class << self
    # Never returns less than 1, never more than the processor count, and never raises: an
    # unreadable total falls back to the processor count, which is the behaviour this replaces.
    # Failing back to the OLD default rather than to the new cap is deliberate — a machine we
    # cannot measure should behave as it did before this file existed, not inherit a number
    # derived from a box it may look nothing like.
    # BUDGETS ON WHAT IS FREE RIGHT NOW, NOT ONLY ON WHAT THE BOX HAS — BUT NEVER BELOW `FLOOR`.
    # Dividing TOTAL memory answers "how many Chromes fit on an idle machine". The condition this
    # file's header says it exists for is a SECOND browser suite already running, and total-memory
    # arithmetic cannot see one: both suites compute the same generous number and oversubscribe
    # together.
    #
    # MEASURED, 2026-08-25: two `bin/rails test test/system/` runs started at once on this 24 GB /
    # 10-core box each took 6 workers — twelve Chromes — and produced **152 and 166 errors** where
    # either alone produces zero. The box swaps and every Capybara wait becomes the coin flip this
    # header already warned about. That reached CI in milder form as BoxSectionsTest failing on two
    # consecutive PRs and passing on every re-run — the CI runner IS this Mac (§15), so a local
    # `bin/ci` and a CI job genuinely collide.
    #
    # NO FLOOR ABOVE 1, DELIBERATELY, AND THAT IS THIS FILE'S EXISTING CONTRACT RATHER THAN A NEW
    # CHOICE. A first draft floored this at 4 to protect local wall time, and
    # `test/worker_budget_test.rb` refused it in two places at once: "never returns zero, however
    # little memory there is" pins 1 on a 512 MB box, and "the budget is per-worker, so the count
    # scales with memory" pins 8 GB -> 2. Their reasoning wins — a constrained box should run the
    # suite slowly and correctly rather than quickly and randomly.
    #
    # WHAT IT COSTS, measured rather than waved away: on this box mid-session with ~8 GB available
    # this returns 2 where the old total-memory formula returned 6, and a solo system run took 34 s
    # at 4 workers against ~31 s at 6. Slower on a busy machine, unchanged on an idle one, and the
    # thing it buys is that two suites can no longer both plan for an empty box.

    # DETECTS THE CONDITION DIRECTLY NOW, INSTEAD OF PROXYING IT THROUGH FREE MEMORY.
    #
    # The available-memory check above was a PROXY for "another browser suite is already running",
    # and on the box this repo actually runs on it is tripped permanently. Measured 2026-08-25:
    # `system-test` took 83-97s on NINE consecutive CI runs, median 84s, never once fast — because
    # the CI runner IS a developer's own Mac (§15) and macOS `available` (free + inactive) on a
    # machine with apps open never looks idle. So the budget returned **1** every time, the
    # protection sat at maximum permanently, and the cost was paid on every run including the vast
    # majority with no second suite anywhere. Local comparison on the same box, same free memory:
    # **1 worker 75.3s, 4 workers 33.6s, zero failures either way.**
    #
    # WHY NOT COUNT CHROME PROCESSES, which is the obvious direct check: it cannot work here.
    # Sampled during a real system run, the process table showed **44 `Google Chrome Helper
    # (Renderer)` processes that were the DEVELOPER'S OWN BROWSER**, identical before, during and
    # after the suite, and `chromedriver` did not appear under that name at all. A count cannot
    # tell our Chrome from the one you are reading this in.
    #
    # SO THE SUITES ANNOUNCE THEMSELVES. `register!` drops a pidfile; `concurrent_browser_suite?`
    # asks whether any OTHER live process has one. That is the exact condition — not a correlate —
    # and it is immune to the browser you have open. A stale pidfile from a killed run is ignored
    # (`Process.kill(0, pid)` proves liveness) and swept.
    #
    # THE PROTECTION IS UNCHANGED WHEN IT APPLIES: with another suite live, this returns exactly
    # what it returned before. What changed is that a merely-busy box no longer reads as a
    # contended one.
    def browser_workers
      cores = processor_count
      total = total_memory_bytes
      return cores if total.nil? || total.zero?

      # Conservative ONLY when a second browser suite is genuinely running — or when we cannot
      # tell, which takes the same branch deliberately: an unanswerable question about contention
      # must not resolve to "assume the box is empty".
      budget = if concurrent_browser_suite?
        [ total, available_memory_bytes || total ].min
      else
        total
      end
      [ [ budget / BYTES_PER_BROWSER_WORKER, 1 ].max, cores ].min
    end

    # Called by ApplicationSystemTestCase as it loads — BEFORE `parallelize`, so this process's own
    # mark is never counted against it, and before any Chrome exists.
    def register!
      require "fileutils"
      FileUtils.mkdir_p(PIDFILE_DIR)
      File.write(File.join(PIDFILE_DIR, "#{Process.pid}.pid"), Time.now.to_i.to_s)
      at_exit { FileUtils.rm_f(File.join(PIDFILE_DIR, "#{Process.pid}.pid")) }
    rescue StandardError
      nil
    end

    # True when ANOTHER live process has registered a browser suite. Sweeps stale pidfiles as it
    # goes, so a killed run cannot throttle every later one forever — the failure mode a naive
    # lockfile would have.
    def concurrent_browser_suite?
      return false unless Dir.exist?(PIDFILE_DIR)

      Dir.children(PIDFILE_DIR).any? do |name|
        pid = name[/\A(\d+)\.pid\z/, 1]&.to_i
        next false if pid.nil? || pid == Process.pid

        if process_alive?(pid)
          true
        else
          File.unlink(File.join(PIDFILE_DIR, name)) rescue nil
          false
        end
      end
    rescue StandardError
      # Cannot tell -> take the conservative branch, same as the comment on `browser_workers` says.
      true
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true   # exists, owned by someone else
    end

    def processor_count
      (Concurrent.available_processor_count || Concurrent.processor_count).floor
    rescue StandardError
      1
    end

    # WHAT IS ACTUALLY FREE, as distinct from installed. nil on an unrecognised platform or an
    # unreadable source, and `browser_workers` then falls back to TOTAL — i.e. exactly the old
    # behaviour, so a machine we cannot measure keeps the number it had before this existed.
    #
    # macOS has no single "available" figure: `vm_stat` reports free pages and INACTIVE pages
    # separately, and inactive memory is reclaimable on demand — counting only `free` would read a
    # perfectly healthy box as starved, because macOS deliberately keeps free near zero. Linux
    # publishes MemAvailable, which already means this.
    def available_memory_bytes
      case RbConfig::CONFIG["host_os"]
      when /darwin/i
        out = `vm_stat 2>/dev/null`
        page = out[/page size of (\d+) bytes/, 1]&.to_i
        free = out[/^Pages free:\s+(\d+)/, 1]&.to_i
        inactive = out[/^Pages inactive:\s+(\d+)/, 1]&.to_i
        page && free && inactive ? (free + inactive) * page : nil
      when /linux/i
        line = File.read("/proc/meminfo")[/^MemAvailable:\s+(\d+) kB/, 1]
        line && line.to_i * 1024
      end
    rescue StandardError
      nil
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
