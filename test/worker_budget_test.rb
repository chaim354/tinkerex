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

  private
    def stub_total(bytes)
      WorkerBudget.singleton_class.alias_method :__real_total, :total_memory_bytes
      WorkerBudget.define_singleton_method(:total_memory_bytes) { bytes }
      # Pin the processor count too, so a machine with fewer than 6 cores doesn't make the
      # scaling assertions fail for a reason they are not about.
      WorkerBudget.singleton_class.alias_method :__real_cores, :processor_count
      WorkerBudget.define_singleton_method(:processor_count) { 64 }
      yield
    ensure
      WorkerBudget.singleton_class.alias_method :total_memory_bytes, :__real_total
      WorkerBudget.singleton_class.alias_method :processor_count, :__real_cores
    end
end
