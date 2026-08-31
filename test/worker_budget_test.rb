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

  # --- the cgroup limit, which is the only honest answer inside a container -------------------

  # /proc/meminfo's MemTotal reports the HOST's memory inside a container, whatever limit the
  # container carries. Measured on the CI box: 33.35 GB host, so browser_workers planned for 8
  # Chromes (~17 GB by this file's own figures) in a container sized far smaller.
  test "a cgroup limit below MemTotal is what total_memory_bytes reports" do
    with_cgroup(max: 8 * (1024**3)) do
      assert_equal 8 * (1024**3), WorkerBudget.total_memory_bytes
    end
  end

  # A container with no memory limit set writes the literal string "max". That is not a number and
  # must not be read as one — fall back to the platform figure, which is then correct.
  test "memory.max reading `max` falls back to the platform figure" do
    with_cgroup(max: "max") do
      assert_equal platform_total, WorkerBudget.total_memory_bytes
    end
  end

  # Bare metal, cgroup v1, or macOS: the file is simply not there.
  test "an absent memory.max falls back to the platform figure" do
    with_cgroup(max: :absent) do
      assert_equal platform_total, WorkerBudget.total_memory_bytes
    end
  end

  test "available is the limit minus what the cgroup is currently using" do
    with_cgroup(max: 8 * (1024**3), current: 3 * (1024**3)) do
      assert_equal 5 * (1024**3), WorkerBudget.available_memory_bytes
    end
  end

  # Never negative: memory.current can exceed memory.max transiently under reclaim.
  test "available floors at zero when current exceeds the limit" do
    with_cgroup(max: 8 * (1024**3), current: 9 * (1024**3)) do
      assert_equal 0, WorkerBudget.available_memory_bytes
    end
  end

  test "an unreadable memory.current leaves available at the whole limit" do
    with_cgroup(max: 8 * (1024**3), current: :absent) do
      assert_equal 8 * (1024**3), WorkerBudget.available_memory_bytes
    end
  end

  # THE BEHAVIOURAL ASSERTION, and the reason the four above are worth having. This is the number
  # that decides how many Chromes start.
  test "the worker count follows the container limit, not the host's memory" do
    with_cgroup(max: 8 * (1024**3)) do
      WorkerBudget.singleton_class.alias_method :__real_cores2, :processor_count
      WorkerBudget.define_singleton_method(:processor_count) { 36 }
      begin
        with_concurrent_suite(false) do
          assert_equal 2, WorkerBudget.browser_workers,
                       "8 GB of container budget at 4 GB per worker is 2, not the host's 8"
        end
      ensure
        WorkerBudget.singleton_class.alias_method :processor_count, :__real_cores2
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
    # A PRIVATE PIDFILE DIRECTORY PER EXAMPLE, AND THE SHARED ONE IS A REAL CROSS-WORKER RACE.
    # These tests write pidfiles for pids that are deliberately DEAD, and `concurrent_browser_suite?`
    # SWEEPS a dead pid's file as it reads it — that sweep is itself one of the behaviours under test
    # here. The unit suite runs 10 processes, so "a stale pidfile is ignored and swept" running in
    # worker 3 would delete the 999_998 file that "a detector that raises" had just written in worker
    # 7, which then scanned an empty directory and read CONTENDED as idle. Observed twice on
    # 2026-08-26 — once locally, once on CI (run 32968647983) — always on the raising-detector test,
    # always passing on re-run and in isolation, which is the signature of exactly this.
    #
    # Reassigning the constant rather than adding a seam to `WorkerBudget`: production code has one
    # directory by design (a second suite must SEE the first), so a configurable path would exist
    # only for tests and could drift from the real one. Restored in the ensure, and `remove_const`
    # first because Ruby warns on reassignment.
    def with_pidfiles(*pids)
      require "fileutils"
      require "tmpdir"
      real_dir = WorkerBudget::PIDFILE_DIR
      swap_pidfile_dir(Dir.mktmpdir("worker-budget-test"))
      paths = pids.map { |pid| File.join(WorkerBudget::PIDFILE_DIR, "#{pid}.pid") }
      paths.each { |p| File.write(p, "1") }
      yield
    ensure
      FileUtils.remove_entry(WorkerBudget::PIDFILE_DIR) rescue nil
      real_dir && swap_pidfile_dir(real_dir)
      @sleeper && (Process.kill("TERM", @sleeper) rescue nil)
      @sleeper && (Process.wait(@sleeper) rescue nil)
    end

    # THE CONSTANT LIVES ON THE SINGLETON, NOT ON `WorkerBudget` ITSELF — `WorkerBudget::PIDFILE_DIR`
    # resolves through it, but `remove_const` must be sent to the object that actually owns it, which
    # is the same distinction the file's own comment records about how it shipped wrong once.
    def swap_pidfile_dir(dir)
      owner = WorkerBudget.singleton_class.const_defined?(:PIDFILE_DIR, false) ? WorkerBudget.singleton_class : WorkerBudget
      owner.send(:remove_const, :PIDFILE_DIR)
      owner.const_set(:PIDFILE_DIR, dir)
    end

    # REAL FILES AT SWAPPED CONSTANTS, matching with_pidfiles above rather than stubbing the reader.
    # The methods under test parse file contents, so stubbing the read away would assert nothing
    # about the parsing — which is where "max" and a trailing newline live.
    #
    # `:absent` points the constant at a path inside the tmpdir that is never created, which is the
    # honest way to model "not a container" — Errno::ENOENT through the real rescue.
    def with_cgroup(max:, current: nil)
      require "fileutils"
      require "tmpdir"
      dir = Dir.mktmpdir("worker-budget-cgroup")
      real_max, real_current = WorkerBudget::CGROUP_MEMORY_MAX, WorkerBudget::CGROUP_MEMORY_CURRENT

      max_path = File.join(dir, "memory.max")
      File.write(max_path, "#{max}\n") unless max == :absent
      swap_const(:CGROUP_MEMORY_MAX, max_path)

      current_path = File.join(dir, "memory.current")
      File.write(current_path, "#{current}\n") unless current.nil? || current == :absent
      swap_const(:CGROUP_MEMORY_CURRENT, current_path)

      yield
    ensure
      FileUtils.remove_entry(dir) rescue nil
      real_max && swap_const(:CGROUP_MEMORY_MAX, real_max)
      real_current && swap_const(:CGROUP_MEMORY_CURRENT, real_current)
    end

    # What this box would report with no cgroup limit in play — the fallback the two tests above
    # assert against. Read through the real reader with the constant pointed at nothing.
    def platform_total
      with_cgroup(max: :absent) { WorkerBudget.send(:platform_total_memory_bytes) }
    end

    # Generalised from swap_pidfile_dir, and for the same recorded reason: a constant assigned in a
    # `class << self` body belongs to the SINGLETON, so the remove_const must be sent to whichever
    # object actually owns it.
    def swap_const(name, value)
      owner = WorkerBudget.singleton_class.const_defined?(name, false) ? WorkerBudget.singleton_class : WorkerBudget
      owner.send(:remove_const, name)
      owner.const_set(name, value)
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
