require "test_helper"
require "tmpdir"

module Library
  class TrashPurgeJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      FileLayer.reset!
      @root = Pathname.new(Dir.mktmpdir("purge-test"))
      @user = User.create!(email: "purge-#{SecureRandom.hex(4)}@example.com")
    end

    teardown do
      FileUtils.remove_entry(@root) if @root&.exist?
      FileLayer.reset!
    end

    # Build a trash entry as Share#delete would, then age it by backdating the ENTRY DIR's mtime —
    # that is what the job reads, so no `trashed_at` column is needed to know when it was trashed.
    #
    # ORDER IS LOAD-BEARING: binwrite the file FIRST, utime the dir SECOND. Creating an entry in a
    # directory updates that directory's mtime, so utime-then-write would silently reset the
    # backdate to now and every age assertion below would be testing nothing.
    #
    # `.to_time` is REQUIRED, not tidiness: Time.current returns an ActiveSupport::TimeWithZone,
    # and File.utime raises `TypeError: can't convert ActiveSupport::TimeWithZone into time` on
    # one. (This plan's first draft omitted it and every test in this file errored.)
    def trash!(node_id, name, bytes, age_days:)
      dir = @root.join(".trash", node_id)
      FileUtils.mkdir_p(dir)
      File.binwrite(dir.join(name), bytes)
      at = (Time.current - age_days.days).to_time
      File.utime(at, at, dir)
      # The fixture must actually age: a backdate that silently no-ops (a read-only mount, a
      # filesystem that ignores utime) would leave every test below asserting nothing. Both sides
      # are fixed values — `at` is computed once here, not read from the clock — so this cannot
      # flake on a slow box; the 2s tolerance is for filesystem mtime GRANULARITY, not timing.
      assert_in_delta at.to_i, File.mtime(dir).to_i, 2, "precondition: the entry must be aged"
      dir
    end

    test "purges entries older than LIBRARY_TRASH_DAYS and leaves fresh ones" do
      old   = trash!(SecureRandom.uuid, "old.stl",   "gone",  age_days: 45)
      fresh = trash!(SecureRandom.uuid, "fresh.stl", "still", age_days: 3)

      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)

      assert_not old.exist?, "an entry past the window is purged"
      assert fresh.exist?,   "an entry inside the window survives"
      assert_equal "still", File.binread(fresh.join("fresh.stl"))
    end

    # 0 is the documented "keep forever" (spec §3.5). A 0 that purged everything immediately would
    # be a data-loss bug wearing a config knob — and `0.days.ago` is `now`, so the obvious
    # implementation does exactly that.
    test "LIBRARY_TRASH_DAYS=0 means never purge, not purge everything" do
      ancient = trash!(SecureRandom.uuid, "a.stl", "keep", age_days: 9999)
      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 0)
      assert ancient.exist?, "0 must mean NEVER purge"
    end

    # A negative value is a typo, not an instruction. It must land on the SAFE side of the same
    # guard rather than on `Time.current - (-1).days` — a cutoff in the FUTURE, which purges the
    # entire trash including what was deleted seconds ago.
    test "a negative LIBRARY_TRASH_DAYS keeps rather than purges everything" do
      ancient = trash!(SecureRandom.uuid, "a.stl", "keep", age_days: 9999)
      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: -1)
      assert ancient.exist?, "a negative window must not mint a cutoff in the future"
    end

    test "purging the bytes leaves the node tombstoned, and undelete then fails cleanly" do
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name: "p.stl", kind: "file", deleted: true,
                          storage_path: nil, mtime: 1_700_000_000_000_000_000)
      trash!(id, "p.stl", "bytes", age_days: 45)

      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)

      node = @user.nodes.find_by!(node_id: id)
      assert node.deleted, "the row is the record that the file existed — never destroy it"
      # The bytes are gone; undelete must say so rather than 500.
      #
      # NotFound, not FetchError, and the difference is not academic: Share#undelete answers
      # FetchError when the trashed bytes are absent AND the library looks unmounted, and
      # `library_present?` reads the root as unmounted when it is EMPTY. This root's only child is
      # `.trash` — so it is precisely the purge leaving `.trash` itself in place (see the test
      # below) that keeps this answer terminal instead of "your NAS is down, retry forever".
      assert_raises(FileLayer::NotFound) do
        FileLayer::Share.new(root: @root.to_s).undelete(@user, node_id: id)
      end
    end

    # The purge removes ENTRY dirs, never `.trash` itself, and that is load-bearing rather than
    # laziness: Share#library_present? uses root EMPTINESS as its "is the NAS mounted?" signal, so
    # purging the last entry out of a library whose only content is trash would make the root read
    # as UNMOUNTED — turning the test above's terminal NotFound into a retryable FetchError, i.e.
    # telling the user their NAS is down when their file is merely gone.
    test "the purge empties .trash but does not remove it" do
      trash!(SecureRandom.uuid, "a.stl", "gone", age_days: 45)

      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)

      assert @root.join(".trash").directory?, ".trash itself must survive the purge"
      assert_empty Dir.children(@root.join(".trash").to_s), "its aged entries must not"
    end

    # The job purges bytes BY AGE, never by consulting rows — so a trash entry whose node was hard
    # deleted, or belongs to another user, is just an aged directory. Pinned because the tempting
    # `Node.find_by!(node_id: entry)` would turn this into a crash (or, with discard_on, a silently
    # skipped purge that leaks the bytes forever).
    test "an entry with no matching node row is purged like any other" do
      orphan = trash!(SecureRandom.uuid, "nobody.stl", "gone", age_days: 45)

      assert_nothing_raised do
        Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)
      end
      assert_not orphan.exist?, "the sweep is by age, not by row"
    end

    test "a missing trash directory is a no-op, not an error" do
      assert_nothing_raised { Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30) }
    end

    # A stray FILE in .trash (a .DS_Store, an operator's scratch note) must not abort the sweep of
    # the real entries beside it.
    test "a non-directory in .trash does not derail the sweep" do
      FileUtils.mkdir_p(@root.join(".trash"))
      File.binwrite(@root.join(".trash", ".DS_Store"), "junk")
      old = trash!(SecureRandom.uuid, "old.stl", "gone", age_days: 45)

      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)

      assert_not old.exist?, "a stray file must not stop the aged entries being purged"
    end

    # The NEGATIVE half of the schedule's gate, matching ScanJobTest's pair exactly. On its own
    # this passes for a `def purge_all!; end`, which is why the positive half below is not optional.
    test "purge_all! no-ops when the deployment is not share-backed" do
      with_env("LIBRARY_BACKEND" => "chunk") do
        assert_no_enqueued_jobs { Library::TrashPurgeJob.purge_all! }
      end
    end

    # The POSITIVE half: proves the no-op above is the gate working, not the method doing nothing.
    # Also pins the root as the ADAPTER's (validated by LibraryBackendCheck) and as a String —
    # Pathname is not an ActiveJob-serializable argument and raises SerializationError at enqueue.
    #
    # Unlike ScanJob this does NOT fan out per user: .trash is one directory under one root, and
    # its entries are keyed by node_id, so one job purges the whole thing. (A share deployment is
    # single-user in practice anyway — but the reason this is one job and ScanJob is N is the
    # filesystem's shape, not the user count.)
    test "purge_all! enqueues one job with the adapter's root" do
      Dir.mktmpdir do |dir|
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir) do
          assert_enqueued_with(job: Library::TrashPurgeJob,
                               # expand_path, matching Share#root — NOT realpath, which would
                               # resolve macOS's /var -> /private/var symlink and diverge.
                               args: [ { root: File.expand_path(dir), trash_days: 30 } ]) do
            Library::TrashPurgeJob.purge_all!
          end
        end
      end
    end

    # LIBRARY_TRASH_DAYS is read HERE and nowhere else — `perform` takes it as a required argument,
    # exactly as it takes `root`, and for ScanJob's stated reason: a default would only serve a
    # hand-rolled call, and would serve it a raw unvalidated ENV read. One reader, at the schedule.
    test "purge_all! reads the window from LIBRARY_TRASH_DAYS" do
      Dir.mktmpdir do |dir|
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir, "LIBRARY_TRASH_DAYS" => "7") do
          assert_enqueued_with(job: Library::TrashPurgeJob,
                               args: [ { root: File.expand_path(dir), trash_days: 7 } ]) do
            Library::TrashPurgeJob.purge_all!
          end
        end
      end
    end

    # Read PER CALL, not at class load. 2a hit exactly this: MAX_DELETE_PCT read into a constant at
    # class-load could not be varied by tests, and the knob the real entry point could not reach was
    # a knob only ENV-mutation could use. The test above already depends on this; this one names it.
    test "the default window is 30 days when LIBRARY_TRASH_DAYS is unset" do
      Dir.mktmpdir do |dir|
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir, "LIBRARY_TRASH_DAYS" => nil) do
          assert_enqueued_with(job: Library::TrashPurgeJob,
                               args: [ { root: File.expand_path(dir), trash_days: 30 } ]) do
            Library::TrashPurgeJob.purge_all!
          end
        end
      end
    end

    # A typo'd window must NAME ITSELF. `Integer("thirty")` raises `invalid value for Integer():
    # "thirty"` — true, useless, and it reaches an operator with no hint that LIBRARY_TRASH_DAYS is
    # the variable to go fix. Raising beats defaulting: silently falling back to 30 on a value the
    # operator clearly meant as something else is how a "0 = keep forever" config quietly starts
    # deleting files after 30 days.
    test "a non-numeric LIBRARY_TRASH_DAYS names itself rather than raising a bare Integer() error" do
      Dir.mktmpdir do |dir|
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir, "LIBRARY_TRASH_DAYS" => "thirty") do
          err = assert_raises(ArgumentError) { Library::TrashPurgeJob.purge_all! }
          assert_match(/LIBRARY_TRASH_DAYS/, err.message,
                       "the operator needs to know WHICH variable is wrong")
          assert_match(/thirty/, err.message, "...and what it is currently set to")
        end
      end
    end

    private

    # Nil deletes the key, which is the operator-forgot-to-set-it case. Mirrors ScanJobTest's
    # helper; FileLayer is reset so the memoized adapter cannot leak the previous test's backend
    # into this one.
    def with_env(vars)
      prior = vars.keys.index_with { |k| ENV[k] }
      vars.each { |k, v| ENV[k] = v }
      FileLayer.reset!
      yield
    ensure
      prior.each { |k, v| ENV[k] = v }
      FileLayer.reset!
    end
  end
end
