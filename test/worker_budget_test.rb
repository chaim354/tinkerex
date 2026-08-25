require "test_helper"
require_relative "support/worker_budget"

# NOTE THIS FILE DOES NOT REQUIRE `application_system_test_case`, AND MUST NOT.
# That file calls `parallelize`, which assigns the GLOBAL `Minitest.parallel_executor` — loading it
# from a unit test would silently re-parallelize the running unit suite partway through. Keeping the
# arithmetic in its own file is what makes it testable at all; that is the reason for the split, not
# tidiness.
class WorkerBudgetTest < ActiveSupport::TestCase
  test "the cap actually bites on this machine, or the change is a no-op nobody would notice" do
    # The point of the whole file. If RAM ever grows enough that the memory budget stops being the
    # binding constraint here, this goes red and someone re-reads whether the cap still earns its
    # keep — rather than it quietly becoming dead code that looks like protection.
    assert_operator WorkerBudget.browser_workers, :<, WorkerBudget.processor_count,
                    "the memory budget is no longer lower than the processor count on this box, so " \
                    "system tests are back to the CPU-derived default this file exists to replace"
  end

  test "never exceeds the processor count, however much memory there is" do
    stub_total(1024 * (1024**3)) do   # 1 TB
      assert_equal WorkerBudget.processor_count, WorkerBudget.browser_workers
    end
  end

  test "never returns zero, however little memory there is" do
    stub_total(512 * (1024**2)) do    # 512 MB — less than one worker's budget
      assert_equal 1, WorkerBudget.browser_workers
    end
  end

  test "an unreadable total falls back to the processor count, not to the cap" do
    # Deliberate: a machine we cannot measure should behave as it did BEFORE this file existed.
    # Falling back to a number derived from some other box would be a guess wearing a measurement's
    # clothes.
    stub_total(nil) do
      assert_equal WorkerBudget.processor_count, WorkerBudget.browser_workers
    end
  end

  test "the budget is per-worker, so the count scales with memory" do
    stub_total(8 * (1024**3))  { assert_equal 2, WorkerBudget.browser_workers }
    stub_total(24 * (1024**3)) { assert_equal 6, WorkerBudget.browser_workers }
  end

  # --- what the availability check buys, and what it must not break -------------------------

  # THE CONTRACT THAT MATTERS, AND IT IS UNCHANGED — ONLY ITS TRIGGER IS.
  #
  # Two browser suites must not both plan for an empty machine: they once divided the SAME 24 GB
  # and took six workers each, and twelve Chromes produced 152 and 166 errors where either alone
  # produces zero (measured 2026-08-25). That protection is asserted here exactly as before. What
  # changed is what SETS it off — a registered concurrent suite, rather than free memory, which on
  # the box this repo runs on was tripped permanently and pinned `system-test` at 83-97s across
  # nine consecutive CI runs. See worker_budget.rb.
  test "a second browser suite forces the conservative budget" do
    with_concurrent_suite(true) do
      stub_total(24 * (1024**3), available: 8 * (1024**3)) do
        assert_equal 2, WorkerBudget.browser_workers,
                     "with another suite live, 24 GB installed but 8 GB free must budget as 8 GB"
      end
    end
  end

  # THE CHANGE, STATED AS AN ASSERTION. A box that is merely BUSY — apps open, a developer's own
  # Chrome holding 44 renderer processes — is not a contended one, and used to be treated as one.
  test "a busy box with NO second suite budgets on total, not on what is free right now" do
    with_concurrent_suite(false) do
      stub_total(24 * (1024**3), available: 8 * (1024**3)) do
        assert_equal 6, WorkerBudget.browser_workers,
                     "no other suite is running, so 8 GB free on a 24 GB box is a busy desktop, " \
                     "not contention — this is the 1-worker-forever bug this replaced"
      end
    end
  end

  # AND AN IDLE BOX IS UNAFFECTED, which is what keeps this from being a slowdown for everyone.
  test "an idle box is unchanged: all of its memory is available" do
    with_concurrent_suite(false) do
      stub_total(24 * (1024**3), available: 24 * (1024**3)) do
        assert_equal 6, WorkerBudget.browser_workers
      end
    end
  end

  # UNREADABLE AVAILABILITY FALLS BACK TO TOTAL, matching the sibling rule above for an unreadable
  # TOTAL: a machine we cannot measure behaves as it did before this existed.
  test "an unreadable available figure falls back to the total, not to zero" do
    with_concurrent_suite(true) do
      stub_total(24 * (1024**3), available: nil) do
        assert_equal 6, WorkerBudget.browser_workers
      end
    end
  end

  # --- the detector itself ------------------------------------------------------------------

  test "our own pidfile never counts as a concurrent suite" do
    with_pidfiles(Process.pid) { assert_not WorkerBudget.concurrent_browser_suite? }
  end

  test "another LIVE process's pidfile does count" do
    with_pidfiles(spawn_sleeper) { assert WorkerBudget.concurrent_browser_suite? }
  end

  # A killed run must not throttle every later run forever, which is the failure mode a naive
  # lockfile has. The stale entry is swept as it is read.
  test "a stale pidfile is ignored and swept rather than throttling forever" do
    with_pidfiles(999_999) do
      assert_not WorkerBudget.concurrent_browser_suite?
      assert_empty Dir.children(WorkerBudget::PIDFILE_DIR).grep(/999999/),
                   "the stale pidfile should have been removed as it was read"
    end
  end

  # CANNOT-TELL TAKES THE CONSERVATIVE BRANCH. An unanswerable question about contention must not
  # resolve to "assume the box is empty" — the whole file leans the other way.
  #
  # Drives the REAL rescue rather than stubbing the method under test: a liveness check that blows
  # up is the realistic way this becomes unanswerable, and stubbing `concurrent_browser_suite?`
  # here would assert nothing about its own error handling.
  test "a detector that raises is treated as contended, not as idle" do
    with_pidfiles(999_998) do
      WorkerBudget.singleton_class.alias_method :__real_alive, :process_alive?
      WorkerBudget.define_singleton_method(:process_alive?) { |_| raise "cannot tell" }
      begin
        assert WorkerBudget.concurrent_browser_suite?,
               "an error while checking for a concurrent suite must read as CONTENDED"
        stub_total(24 * (1024**3), available: 4 * (1024**3)) do
          assert_equal 1, WorkerBudget.browser_workers
        end
      ensure
        WorkerBudget.singleton_class.alias_method :process_alive?, :__real_alive
      end
    end
  end

  private
    # ALIAS-BASED, MATCHING `stub_total` BELOW. Minitest 6 no longer ships `minitest/mock`, so
    # `Object#stub` is unavailable — and adding a gem to stub one predicate would be a dependency
    # bought for a one-line swap (§9 asks for a licence check on every new dep).
    def with_concurrent_suite(value)
      WorkerBudget.singleton_class.alias_method :__real_concurrent, :concurrent_browser_suite?
      WorkerBudget.define_singleton_method(:concurrent_browser_suite?) { value }
      yield
    ensure
      WorkerBudget.singleton_class.alias_method :concurrent_browser_suite?, :__real_concurrent
    end

    # Real pidfiles in the real directory: the detector reads the filesystem, so stubbing that away
    # would test nothing. Cleaned up whatever happens.
    def with_pidfiles(*pids)
      require "fileutils"
      FileUtils.mkdir_p(WorkerBudget::PIDFILE_DIR)
      paths = pids.map { |pid| File.join(WorkerBudget::PIDFILE_DIR, "#{pid}.pid") }
      paths.each { |p| File.write(p, "1") }
      yield
    ensure
      paths&.each { |p| FileUtils.rm_f(p) }
      @sleeper && (Process.kill("TERM", @sleeper) rescue nil)
      @sleeper && (Process.wait(@sleeper) rescue nil)
    end

    def spawn_sleeper
      @sleeper = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
    end

    # PINS AVAILABILITY TO THE STUBBED TOTAL, WHICH IS NOT OPTIONAL SINCE browser_workers STARTED
    # CONSULTING IT. `browser_workers` takes min(total, available); left unstubbed, `available`
    # reports THIS MACHINE'S real free memory and every assertion below silently measures the box
    # the suite happens to run on instead of the number it names. That is not hypothetical: it
    # turned "1 TB of RAM gives you all 64 cores" into 2 on the first run after the change, because
    # ~8 GB was actually free. `total` is the right stand-in — a machine with nothing else running
    # has all of its memory available, which is exactly the world these assertions describe.
    def stub_total(bytes, available: bytes)
      WorkerBudget.singleton_class.alias_method :__real_total, :total_memory_bytes
      WorkerBudget.define_singleton_method(:total_memory_bytes) { bytes }
      WorkerBudget.singleton_class.alias_method :__real_avail, :available_memory_bytes
      WorkerBudget.define_singleton_method(:available_memory_bytes) { available }
      # Pin the processor count too, so a machine with fewer than 6 cores doesn't make the
      # scaling assertions fail for a reason they are not about.
      WorkerBudget.singleton_class.alias_method :__real_cores, :processor_count
      WorkerBudget.define_singleton_method(:processor_count) { 64 }
      yield
    ensure
      WorkerBudget.singleton_class.alias_method :total_memory_bytes, :__real_total
      WorkerBudget.singleton_class.alias_method :available_memory_bytes, :__real_avail
      WorkerBudget.singleton_class.alias_method :processor_count, :__real_cores
    end
end
