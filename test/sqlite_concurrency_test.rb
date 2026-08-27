require "test_helper"
require "sqlite3"

# THE FOUR SETTINGS THAT KEEP `SQLite3::BusyException` AWAY, EACH OF WHICH CAN BE UNDONE IN ONE
# LINE WITH NOTHING GOING RED — tinkerex#124 (CLAUDE.md §12.7).
#
# That intermittent was diagnosed in 2026-08-20 as a stalled fsync and fixed with `timeout: 15000`;
# it was then REOPENED because it recurred on 2026-08-23. What closed it was not another number:
# the mechanism §12.7 blamed — "every commit, mutation, restore and conflict serializes on
# `User#next_seq!`" — left this process with the sync engine on 2026-08-25 (Arc D Part 2), two days
# AFTER that last observation. `next_seq!` now has zero callers here; every remaining mention is a
# comment. Re-measured on the engine-free tree under the sustained disk I/O §12.7 says the failure
# needs: 0 of 12 share-leg runs, against 3 of 8 when it was first measured.
#
# So this file does not re-fix anything. It pins the four properties the current health RESTS on,
# because "we could not reproduce it" is the weakest possible reason to consider a flake finished
# and none of these four is checked anywhere else:
#
#   1. WAL journal mode — in rollback-journal mode a writer blocks every reader, and this returns
#      immediately.
#   2. One database FILE PER PARALLEL WORKER — test_helper's own comment records that this was
#      once documented backwards, and that the wrong version "was cited as the explanation" for
#      this very intermittent.
#   3. The configured busy wait REALLY REACHING THE CONNECTION. §14e says `PRAGMA busy_timeout`
#      reads 0 and that checking it "gives the wrong answer; measure the wait instead" — and then
#      nothing measured it. `busy_handler_timeout` is WRITE-ONLY in the sqlite3 gem (verified:
#      `respond_to?(:busy_handler_timeout)` is false), so behaviour is the only instrument there is.
#   4. `BEGIN IMMEDIATE`, not `BEGIN`. A deferred transaction that upgrades from read to write can
#      be refused with SQLITE_BUSY *without the busy handler being called at all* — SQLite does
#      that deliberately, to break a deadlock it cannot otherwise resolve. No timeout can fix that
#      one, so a regression here would look exactly like "the fix stopped working".
class SqliteConcurrencyTest < ActiveSupport::TestCase
  # THE PROBE NEEDS THE WRITE LOCK, AND A TRANSACTIONAL TEST IS ALREADY HOLDING IT. Rails opens
  # each test's wrapping transaction with BEGIN IMMEDIATE (property 4 below), which takes the
  # single write lock at BEGIN and keeps it for the whole test — so a second connection could
  # never acquire it and the measurement would time out instead of measuring. Nothing here writes
  # a row, so there is no state to roll back: the probes take a lock and release it.
  self.use_transactional_tests = false

  def sqlite? = ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)

  def db_path = ActiveRecord::Base.connection_pool.db_config.configuration_hash[:database]

  setup do
    skip "SQLite-only invariants (DATABASE_URL selects Postgres)" unless sqlite?
  end

  test "the journal mode is WAL" do
    mode = ActiveRecord::Base.connection.select_value("PRAGMA journal_mode").to_s
    assert_equal "wal", mode.downcase, <<~MSG
      journal_mode is #{mode.inspect}, not WAL.

      In rollback-journal mode a writer takes an exclusive lock on the whole database and every
      reader blocks behind it, which is how tinkerex#124's `database is locked` gets back in.
    MSG
  end

  test "an ordinary transaction begins IMMEDIATE, not deferred" do
    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end
    ActiveRecord::Base.transaction { ActiveRecord::Base.connection.select_value("SELECT 1") }
    ActiveSupport::Notifications.unsubscribe(sub)

    begins = statements.grep(/\ABEGIN/i)
    refute_empty begins, "no BEGIN was recorded — the probe did not observe a real transaction"
    assert begins.any? { |s| s.match?(/BEGIN IMMEDIATE/i) }, <<~MSG
      Transactions are opening as #{begins.inspect}, not BEGIN IMMEDIATE.

      A deferred transaction that upgrades from read to write can be refused with SQLITE_BUSY
      WITHOUT the busy handler running — SQLite skips it on purpose there, because retrying could
      deadlock. `timeout:` cannot cover that case, so this is not a tuning question.
    MSG
  end

  test "each parallel worker has its own database file" do
    worker = ENV["CHUNK_STORE_WORKER"]
    # test_helper's parallelize_setup sets this per worker. Absent means a single-process run
    # (fewer than the parallelization threshold, or PARALLEL_WORKERS=1), where there is no second
    # worker to share with and nothing to assert.
    skip "single-process run — no parallel workers to isolate" if worker.nil?

    assert_match(/_#{Regexp.escape(worker)}\z/, db_path.to_s, <<~MSG)
      Worker #{worker} is using #{db_path.inspect}, which does not carry its worker suffix.

      Parallel workers sharing one SQLite file is the shape that makes every worker a competing
      writer. test_helper records that this was once documented backwards and that the wrong
      version was cited as the explanation for tinkerex#124.
    MSG
  end

  # MEASURED, NOT READ. There is no getter for the value this asserts — the pragma reads 0 by
  # design and the gem exposes no reader — so the only honest check is to make a writer wait and
  # watch. It deliberately does NOT wait the full 15 s: proving the wait is LONG (not 0, not a few
  # ms) and that it ends in SUCCESS rather than an exception is the property that matters, and it
  # costs ~700 ms instead of failing the suite's time budget.
  test "a blocked writer waits for the configured timeout instead of raising at once" do
    configured = ActiveRecord::Base.connection_pool.db_config.configuration_hash[:timeout].to_i
    assert_operator configured, :>=, 1_000,
      "database.yml's timeout is #{configured}ms — this probe assumes a second-scale wait"

    blocker = SQLite3::Database.new(db_path.to_s)
    blocker.execute("BEGIN IMMEDIATE")   # takes the single write lock

    outcome = nil
    started = Concurrent::AtomicBoolean.new(false)
    writer = Thread.new do
      started.make_true
      begin
        ActiveRecord::Base.connection_pool.with_connection do |c|
          c.transaction { c.select_value("SELECT 1") }   # needs the write lock (IMMEDIATE)
        end
        outcome = :acquired
      rescue SQLite3::BusyException, ActiveRecord::StatementInvalid => e
        outcome = e
      end
    end

    Thread.pass until started.true?
    sleep 0.6

    # TWO WAYS TO FAIL HERE AND THEY MEAN OPPOSITE THINGS, so they get separate messages — a
    # failure that sends the next reader after the wrong cause costs more than no failure at all.
    if outcome == :acquired
      flunk <<~MSG
        The competing writer acquired the lock immediately, while another connection was holding
        it with BEGIN IMMEDIATE. It never had to wait, so this probe measured nothing.

        The usual cause is transactions no longer opening IMMEDIATE: a deferred one takes no write
        lock at BEGIN, so it sails through here and is refused LATER, on upgrade — the one
        SQLITE_BUSY the busy handler is never called for. See the IMMEDIATE test above.
      MSG
    end
    assert_nil outcome, <<~MSG
      A writer blocked by another connection gave up after ~600ms with #{outcome.inspect}, but
      database.yml configures a #{configured}ms wait.

      That means the timeout is not reaching the connection. §14e: `PRAGMA busy_timeout` reads 0
      whatever the setting, so it cannot tell you this — only the wait can.
    MSG
    assert writer.alive?, "the competing writer already finished; it never actually blocked"

    blocker.execute("ROLLBACK")
    writer.join(configured / 1000.0 + 5)

    assert_equal :acquired, outcome, <<~MSG
      The blocked writer did not succeed once the lock was released (got #{outcome.inspect}).

      Waiting is only half the property — the point of the busy handler is that the write then
      GOES THROUGH, rather than surfacing as tinkerex#124's `database is locked`.
    MSG
  ensure
    begin
      blocker&.execute("ROLLBACK")
    rescue SQLite3::SQLException
      # already rolled back on the success path
    end
    blocker&.close
    writer&.join(5)
  end
end
