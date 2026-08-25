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

  # THE WHOLE POINT OF CONSULTING `available`. A box with plenty of RAM that is already busy — a
  # second browser suite, a developer's browser, anything — must not plan as though the machine
  # were empty. Before this, both suites divided the SAME 24 GB and took six workers each; twelve
  # Chromes produced 152 and 166 errors where either alone produces zero (measured 2026-08-25).
  test "a busy box takes fewer workers than its total memory alone would allow" do
    stub_total(24 * (1024**3), available: 8 * (1024**3)) do
      assert_equal 2, WorkerBudget.browser_workers,
                   "24 GB installed but 8 GB free must budget as 8 GB, not as 24 GB"
    end
  end

  # AND AN IDLE BOX IS UNAFFECTED, which is what keeps this from being a slowdown for everyone.
  test "an idle box is unchanged: all of its memory is available" do
    stub_total(24 * (1024**3), available: 24 * (1024**3)) do
      assert_equal 6, WorkerBudget.browser_workers
    end
  end

  # UNREADABLE AVAILABILITY FALLS BACK TO TOTAL, matching the sibling rule one test up for an
  # unreadable TOTAL: a machine we cannot measure behaves as it did before this existed, rather
  # than inheriting a number derived from a box it may look nothing like.
  test "an unreadable available figure falls back to the total, not to zero" do
    stub_total(24 * (1024**3), available: nil) do
      assert_equal 6, WorkerBudget.browser_workers
    end
  end

  private
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
