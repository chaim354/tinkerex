require "test_helper"
require "tmpdir"
require_relative "../../support/fake_s3"

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
      with_env("LIBRARY_BACKEND" => "chunk_remote",
               "CHUNK_REMOTE_URL" => "http://sync.invalid",
               "SYNC_ADMIN_TOKEN" => "test-token") do
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

    # --- the s3 reaper ---------------------------------------------------------------------
    #
    # An S3 trash is a key PREFIX. There is no entry directory, so there is no directory mtime to
    # age against — the share's whole mechanism is absent, not merely different. The age comes from
    # the OBJECTS' own last_modified, which the listing already carries.

    # THE PHASE 3 TRAP'S QUIETER HALF, PINNED. This gate was `is_a?(FileLayer::Share)` too, and it
    # answered false for s3 exactly as ScanJob's did: purge_all! enqueued nothing and said nothing,
    # so an s3 user's deleted bytes were never reclaimed. Reproduced red before the fix.
    #
    # It is the quieter of the two because a library that is never indexed at least LOOKS empty,
    # whereas a trash that is never purged looks exactly like a working library until the storage
    # bill arrives. CLAUDE.md names both gates; the plan's Landmine 5 names only ScanJob's.
    test "purge_all! enqueues for an s3 deployment, not only a share one" do
      with_env(S3_ENV) do
        assert_enqueued_with(job: Library::TrashPurgeJob, args: [ { trash_days: 30 } ]) do
          Library::TrashPurgeJob.purge_all!
        end
      end
    end

    # No root, and no bucket or credentials either — same reason as ScanJob's: ActiveJob serializes
    # arguments into the queue's database. The window is all that travels.
    test "the s3 purge job carries no bucket and no credentials" do
      with_env(S3_ENV) do
        Library::TrashPurgeJob.purge_all!
        args = enqueued_jobs.last["arguments"].first
        assert_equal [ "trash_days" ], args.keys.grep_v(/_aj_/)
      end
    end

    test "an s3 entry whose objects are all past the window is purged, a fresh one is not" do
      fake = FakeS3.new
      old_id, fresh_id = SecureRandom.uuid, SecureRandom.uuid
      fake.seed!("library/.trash/#{old_id}/old.stl", "gone", last_modified: 45.days.ago)
      fake.seed!("library/.trash/#{fresh_id}/fresh.stl", "still", last_modified: 3.days.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }

      assert_nil fake.objects["library/.trash/#{old_id}/old.stl"], "an aged entry is purged"
      assert fake.objects["library/.trash/#{fresh_id}/fresh.stl"], "a fresh entry survives"
    end

    # EVERY object under the entry must be past the window, not just one of them. An entry is one
    # user-visible file, so purging it on the strength of its oldest object would delete bytes that
    # are inside the retention window the operator configured — and there is no version to restore
    # (spec decision 3). When they disagree, the entry stays: the next run re-asks, and the cost of
    # waiting a week is a few KB.
    test "an s3 entry with any object inside the window is not purged" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      fake.seed!("library/.trash/#{id}/a.stl", "old", last_modified: 45.days.ago)
      fake.seed!("library/.trash/#{id}/b.stl", "new", last_modified: 1.day.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }

      assert fake.objects["library/.trash/#{id}/a.stl"], "the aged object stays with its entry"
      assert fake.objects["library/.trash/#{id}/b.stl"], "the fresh object must not be purged"
    end

    # 0 is "keep forever" (spec §3.5) on every backend, and the s3 reaper must answer it BEFORE it
    # lists anything. `Time.current - 0.days` is NOW, so the obvious implementation purges the
    # entire trash — the same data-loss bug wearing a config knob that 2b pinned for share.
    test "LIBRARY_TRASH_DAYS=0 means never purge on s3 either" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      fake.seed!("library/.trash/#{id}/a.stl", "keep", last_modified: 9999.days.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 0) }

      assert fake.objects["library/.trash/#{id}/a.stl"], "0 must mean NEVER purge"
      assert_equal 0, fake.calls[:list_objects_v2], "and must cost nothing — no listing at all"
    end

    test "a negative window keeps rather than purges everything on s3" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      fake.seed!("library/.trash/#{id}/a.stl", "keep", last_modified: 9999.days.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: -1) }

      assert fake.objects["library/.trash/#{id}/a.stl"], "a negative window must not mint a cutoff in the future"
    end

    # The reaper lists BY the trash prefix, so this should be impossible — which is exactly why it
    # is asserted. The library's live objects are the user's actual files; a prefix bug here does
    # not lose a trashed copy, it loses the file.
    test "the s3 purge never touches the library's live objects" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      fake.seed!("library/keep.stl", "live", last_modified: 9999.days.ago)
      fake.seed!("library/.trash/#{id}/a.stl", "gone", last_modified: 45.days.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }

      assert_equal "live", fake.objects["library/keep.stl"].body, "an ancient LIVE file is not trash"
      assert_nil fake.objects["library/.trash/#{id}/a.stl"]
    end

    # Same rule as share: the bytes go, the row stays. The row is what makes a project say "file
    # missing" instead of an attachment silently vanishing.
    test "purging s3 bytes leaves the node tombstoned" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name: "p.stl", kind: "file", deleted: true,
                          storage_path: nil, mtime: 1_700_000_000_000_000_000)
      fake.seed!("library/.trash/#{id}/p.stl", "bytes", last_modified: 45.days.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }

      assert @user.nodes.find_by!(node_id: id).deleted, "the row is the record that the file existed"
      assert_nil fake.objects["library/.trash/#{id}/p.stl"]
    end

    # By AGE, never by row — a trash entry whose node was hard-deleted is just an aged prefix.
    # Looking the node up would turn that into a crash, or a silently skipped purge that leaks the
    # bytes forever.
    test "an s3 entry with no matching node row is purged like any other" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      fake.seed!("library/.trash/#{id}/nobody.stl", "gone", last_modified: 45.days.ago)

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }

      assert_nil fake.objects["library/.trash/#{id}/nobody.stl"], "the sweep is by age, not by row"
    end

    test "an empty s3 trash is a no-op, not an error" do
      fake = FakeS3.new
      fake.seed!("library/live.stl", "only a live file here")

      assert_nothing_raised do
        with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }
      end
    end

    # FakeS3 pages at TWO keys. A reaper that read only the first page would purge a fraction of
    # the trash and report success forever — the leak this job exists to close, just slower. Six
    # objects is four pages.
    test "the s3 purge pages through the whole trash" do
      fake = FakeS3.new
      ids = 3.times.map { SecureRandom.uuid }
      ids.each do |id|
        fake.seed!("library/.trash/#{id}/a.stl", "a", last_modified: 45.days.ago)
        fake.seed!("library/.trash/#{id}/b.stl", "b", last_modified: 45.days.ago)
      end

      with_injected_s3(fake) { Library::TrashPurgeJob.perform_now(trash_days: 30) }

      assert_empty fake.objects.keys.grep(%r{/\.trash/}), "every page's entries must be purged"
    end

    # A LISTING THAT DIED PARTWAY MUST PURGE NOTHING, and this is the sharper cousin of Landmine 4
    # rather than a copy of it. A partial listing can show an entry's aged object while the page
    # carrying its fresh sibling never arrives — so "every object is past the window" becomes true
    # of an entry for which it is false, and the reaper deletes bytes inside the retention window.
    # Hence: list to completion FIRST, delete only after. `fault_after!`, not `fault!`, for the
    # reason FakeS3 spells out — faulting page 1 tests nothing, since a reaper that never lists
    # also purges nothing and would pass.
    test "an s3 listing that fails partway purges nothing" do
      fake = FakeS3.new
      ids = 3.times.map { SecureRandom.uuid }
      ids.each { |id| fake.seed!("library/.trash/#{id}/a.stl", "x", last_modified: 45.days.ago) }
      fake.fault_after!(:list_objects_v2, 1, "InternalError")

      with_injected_s3(fake) do
        assert_raises(FileLayer::FetchError) { Library::TrashPurgeJob.perform_now(trash_days: 30) }
      end

      assert_equal 3, fake.objects.keys.grep(%r{/\.trash/}).size,
                   "a partial listing must not be acted on — nothing was deleted"
      assert_equal 0, fake.calls[:delete_object], "not even the entries page 1 fully showed"
    end

    # THROUGH THE REAL `delete`, AND THE ONLY TEST HERE THAT IS. Every other s3 purge test seeds a
    # trash object with an explicit last_modified, which quietly asserts nothing about the thing the
    # whole window rests on: THAT A TRASH OBJECT'S AGE IS ITS DELETE TIME, not its file's age.
    #
    # It holds because S3#delete is a COPY, and a copy is a NEW OBJECT with a NEW Last-Modified —
    # real S3, and every store this backend points at (SeaweedFS/MinIO/R2/Ceph). So a file the user
    # made two years ago and deleted today is a trash object from today, and the 30-day window means
    # 30 days from the DELETE.
    #
    # A fake that copied the source's timestamp forward would invert it — the same file would be
    # purged the day it was deleted, inside the window the operator configured, with no version to
    # restore. FakeS3#do_copy did exactly that, and nothing could see it: no test reached delete.
    # This is the CGI.escape shape again (a fake disagreeing with reality where the suite cannot
    # look), so the link is asserted end-to-end rather than reasoned about.
    test "a two-year-old file deleted today survives the window — the trash ages from the DELETE" do
      fake = FakeS3.new
      body = "an old bracket"
      fake.seed!("library/old.stl", body, last_modified: 2.years.ago)
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "old.stl", kind: "file",
                                 storage_path: "old.stl", size: body.bytesize,
                                 content_hash: "md5:#{Digest::MD5.hexdigest(body)}",
                                 mtime: 2.years.ago.to_i * 1_000_000_000)

      adapter = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                  secret_access_key: "sk", prefix: "library", client: fake.client)
      FileLayer.current = adapter
      adapter.delete(@user, node_id: node.node_id)

      trash_key = "library/.trash/#{node.node_id}/old.stl"
      assert fake.objects[trash_key], "delete moves the bytes to .trash"

      Library::TrashPurgeJob.perform_now(trash_days: 30)

      assert fake.objects[trash_key],
             "a file deleted TODAY must survive a 30-day window, however old the file itself was"
    ensure
      FileLayer.reset!
    end

    # THE SHARE'S "NEVER REMOVE `.trash` ITSELF" RULE HAS NO S3 ANALOGUE, and this test pins what
    # happens instead. It is the one place the two reapers genuinely diverge, so it is written down
    # rather than discovered.
    #
    # The share rule is: purge the ENTRY dirs, never `.trash` itself, because Share#library_present?
    # reads root EMPTINESS as "the NAS is unmounted" — so emptying a library whose only content was
    # trash would flip undelete's terminal NotFound ("your file is gone") to a retryable FetchError
    # ("your NAS is down"). Leaving an empty directory behind costs nothing and keeps it honest.
    #
    # ON S3 THERE IS NOTHING TO LEAVE BEHIND. `.trash/` is a key prefix: it has no existence apart
    # from the objects under it, so an "empty `.trash`" is not a thing that can be stored. And
    # S3#library_present? uses the SAME emptiness signal (an empty listing), so the consequence
    # transfers even though the mechanism cannot.
    #
    # WHAT THIS IS NOT: a bug this job introduced. It is FileLayer::S3's own settled trade arriving
    # in one more place. On S3 an empty listing is genuinely ambiguous — a purged-empty library, a
    # mistyped prefix and a revoked credential are indistinguishable — and the adapter already
    # decided, at length and in two places (#read, #undelete), to prefer the RETRYABLE answer in
    # that ambiguity: "a genuinely emptied library retried is harmless; a live library burned to
    # 'failed' is not." The bytes are gone either way; the only question is which sentence the user
    # reads, and this is the one the adapter chose everywhere else.
    #
    # THE ONLY TRUE ANALOGUE would be a zero-byte `<prefix>/.trash/` directory-marker object minted
    # by S3#delete — the exact counterpart of Share#delete's mkdir_p, with the same lifetime and
    # the same purpose, and the observer already skips markers (Landmine 6) and `.trash` besides.
    # DELIBERATELY NOT TAKEN HERE: it writes an object the user never asked for into the user's own
    # bucket, and it belongs to the delete path (Task 6), not the reaper. Flagged for review rather
    # than decided unilaterally. If it is ever taken, this test is the one to delete.
    test "purging an s3 library empty makes undelete answer retryable rather than terminal" do
      fake = FakeS3.new
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name: "p.stl", kind: "file", deleted: true,
                          storage_path: nil, mtime: 1_700_000_000_000_000_000)
      # The library's ONLY object is this one trashed file — the corner, and the whole of it.
      fake.seed!("library/.trash/#{id}/p.stl", "bytes", last_modified: 45.days.ago)

      adapter = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                  secret_access_key: "sk", prefix: "library", client: fake.client)
      FileLayer.current = adapter
      Library::TrashPurgeJob.perform_now(trash_days: 30)

      assert_empty fake.objects, "the purge emptied the library — there is no `.trash` left to hold"
      # Share answers NotFound here (its own test, above, pins that). This is the divergence.
      assert_raises(FileLayer::FetchError) { adapter.undelete(@user, node_id: id) }
    ensure
      FileLayer.reset!
    end

    private

    # Mirrors ScanJobTest's, including the load-bearing ensure: a direct FileLayer.current= does not
    # set test_helper's @file_layer_backend_pinned, so nothing else will clean up after it.
    def with_injected_s3(fake)
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", prefix: "library",
                                            client: fake.client)
      yield
    ensure
      FileLayer.reset!
    end

    S3_ENV = {
      "LIBRARY_BACKEND" => "s3", "LIBRARY_S3_BUCKET" => "b",
      "LIBRARY_S3_ACCESS_KEY_ID" => "ak", "LIBRARY_S3_SECRET_ACCESS_KEY" => "sk"
    }.freeze

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
