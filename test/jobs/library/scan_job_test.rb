require "test_helper"
require "tmpdir"
require_relative "../../support/fake_s3"

module Library
  class ScanJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup { FileLayer.reset! }
    teardown { FileLayer.reset! }

    test "a scan indexes the library into nodes" do
      Dir.mktmpdir do |dir|
        user = user!
        File.binwrite(File.join(dir, "j.stl"), "bytes")

        Library::ScanJob.perform_now(user_id: user.id, root: dir)

        assert user.nodes.find_by(storage_path: "j.stl"), "the scan must index the file"
      end
    end

    # #perform is a COMMAND — it must scan the root it was handed. Pinned explicitly because the
    # tempting alternative (gating perform on LIBRARY_BACKEND, as an early draft did) makes an
    # operator's explicit scan silently do nothing, and the test above would then be RED for a
    # reason easily mistaken for a fixture problem.
    test "perform scans the root it is given rather than gating on the deployment backend" do
      Dir.mktmpdir do |dir|
        user = user!
        File.binwrite(File.join(dir, "explicit.stl"), "bytes")

        with_env("LIBRARY_BACKEND" => "chunk_remote",
               "CHUNK_REMOTE_URL" => "http://sync.invalid",
               "SYNC_ADMIN_TOKEN" => "test-token",
               "SYNC_PUBLIC_URL" => "http://sync.invalid") do
          Library::ScanJob.perform_now(user_id: user.id, root: dir)
        end

        assert user.nodes.find_by(storage_path: "explicit.stl"),
               "an explicitly commanded scan must not no-op just because the deployment is chunk-mode"
      end
    end

    # An UnsafeScan (the missing-root / unmounted-NAS guard) must reach the queue as a failed
    # execution rather than being swallowed by a discard_on. The MESSAGE is asserted, not just the
    # class: UnsafeScan is raised from two places (missing root, mass-deletion), and a test that
    # only names the class would pass on the wrong one.
    test "an unsafe scan is reported, not swallowed" do
      user = user!
      root = "/nonexistent-#{SecureRandom.hex(4)}"

      err = assert_raises(Library::Scanner::UnsafeScan) do
        Library::ScanJob.perform_now(user_id: user.id, root: root)
      end
      assert_match(/library root .*#{Regexp.escape(File.basename(root))} is missing/, err.message,
                   "the refusal must name the root the operator configured")
    end

    # No retry_on for UnsafeScan: retrying cannot remount a NAS, and the 15-minute schedule is
    # itself a better retry (it re-observes rather than replaying a stale verdict). Pinned so a
    # future `retry_on` has to delete this test rather than quietly add four more failures per pass.
    test "an unsafe scan is not retried" do
      user = user!
      assert_no_enqueued_jobs do
        assert_raises(Library::Scanner::UnsafeScan) do
          Library::ScanJob.perform_now(user_id: user.id, root: "/nonexistent-#{SecureRandom.hex(4)}")
        end
      end
    end

    # The user can be deleted between scan_all!'s fan-out and the job running. Nothing to scan and
    # nothing wrong.
    test "a deleted user is discarded, not failed" do
      Dir.mktmpdir do |dir|
        assert_nothing_raised do
          Library::ScanJob.perform_now(user_id: -1, root: dir)
        end
      end
    end

    # THE case unreadable_dirs exists for: the mass-deletion guard does NOT trip (nothing is being
    # tombstoned at all here), so the scan succeeds and quietly excludes the subtree. Without this
    # signal the only trace is a per-directory line in the Scanner's log.
    test "a successful scan that could not read everything says so" do
      Dir.mktmpdir do |dir|
        user = user!
        FileUtils.mkdir_p(File.join(dir, "secret"))
        File.binwrite(File.join(dir, "secret", "hidden.stl"), "h")
        File.binwrite(File.join(dir, "seen.stl"), "s")
        File.chmod(0o000, File.join(dir, "secret"))

        log = capture_log do
          Library::ScanJob.perform_now(user_id: user.id, root: dir)
        ensure
          File.chmod(0o755, File.join(dir, "secret"))
        end

        assert user.nodes.find_by(storage_path: "seen.stl"), "one bad directory must not abort the scan"
        assert_match(/1 directories were unreadable/, log)
        assert_match(/"secret"/, log, "the operator needs to know WHICH directory")
      end
    end

    test "a healthy scan logs no unreadable warning" do
      Dir.mktmpdir do |dir|
        user = user!
        File.binwrite(File.join(dir, "fine.stl"), "f")

        log = capture_log { Library::ScanJob.perform_now(user_id: user.id, root: dir) }

        assert_no_match(/unreadable/, log)
      end
    end

    # The NEGATIVE half of the schedule's gate. On its own this passes for a `def scan_all!; end`,
    # which is why the positive test below is not optional.
    test "scan_all! no-ops when the deployment is not share-backed" do
      user!
      with_env("LIBRARY_BACKEND" => "chunk_remote",
               "CHUNK_REMOTE_URL" => "http://sync.invalid",
               "SYNC_ADMIN_TOKEN" => "test-token",
               "SYNC_PUBLIC_URL" => "http://sync.invalid") do
        assert_no_enqueued_jobs { Library::ScanJob.scan_all! }
      end
    end

    # The POSITIVE half: proves the no-op above is the gate working and not the method doing
    # nothing. Also pins the root as the ADAPTER's (validated by LibraryBackendCheck), not a raw
    # ENV read, and as a String — Pathname is not an ActiveJob-serializable argument.
    test "scan_all! fans out one job per user with the adapter's root" do
      Dir.mktmpdir do |dir|
        user = user!
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir) do
          assert_enqueued_with(job: Library::ScanJob,
                               # expand_path, matching Share#root — NOT realpath, which would
                               # resolve macOS's /var -> /private/var symlink and diverge.
                               args: [ { user_id: user.id, root: File.expand_path(dir) } ]) do
            Library::ScanJob.scan_all!
          end
        end
      end
    end

    # THE PAUSE (K §3): a fresh share install -- no `library.root` row -- schedules nothing until its
    # owner has said which folder is the library. One assertion per method, so deleting either gate is
    # its own red; the confirmed half proves the no-op is the gate and not the methods doing nothing.
    test "while a share library's folder is unconfirmed, scan_all! and enqueue_first_for enqueue nothing" do
      Dir.mktmpdir do |dir|
        user = user!
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir) do
          Setting.forget(Tinkerex::LibraryRoot::KEY)
          assert_no_enqueued_jobs(only: Library::ScanJob) { Library::ScanJob.scan_all! }
          assert_no_enqueued_jobs(only: Library::ScanJob) { Library::ScanJob.enqueue_first_for(user) }

          Setting.put(Tinkerex::LibraryRoot::KEY, "")
          assert_enqueued_jobs(1, only: Library::ScanJob) { Library::ScanJob.scan_all! }
          assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: user.id, root: File.expand_path(dir) } ]) do
            Library::ScanJob.enqueue_first_for(user)
          end
        end
      end
    end

    # THE FOLDER IS A SHARE FACT. An s3 library has a prefix, not a folder to confirm, so a missing
    # row must not pause its scans -- the regression would be the Phase 3 trap below in a new costume.
    test "an s3 deployment with no folder setting still schedules its scans" do
      user = user!
      with_env(S3_ENV) do
        Setting.forget(Tinkerex::LibraryRoot::KEY)
        assert_enqueued_jobs(1, only: Library::ScanJob) { Library::ScanJob.scan_all! }
        assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: user.id } ]) do
          Library::ScanJob.enqueue_first_for(user)
        end
      end
    end

    # THE PHASE 3 TRAP, PINNED. Until this test existed the gate was `is_a?(FileLayer::Share)` —
    # correct while Share was the only scanned backend, and silently wrong the moment FileLayer::S3
    # landed: scan_all! answered false, enqueued nothing, raised nothing, and an s3 library was
    # never indexed while the whole suite stayed green. Reproduced before the fix, not reasoned.
    #
    # The gate now asks a CAPABILITY (`scannable?`), so this test is not really about s3 — it is
    # about the NEXT backend, which must state its own answer rather than inherit a false from an
    # is_a? it never heard of.
    test "scan_all! fans out for an s3 deployment, not only a share one" do
      user = user!
      with_env(S3_ENV) do
        assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: user.id } ]) do
          Library::ScanJob.scan_all!
        end
      end
    end

    # The s3 fan-out carries NO target, and that asymmetry with share's `root:` is deliberate
    # rather than an omission. ActiveJob SERIALIZES arguments into the queue's database, where
    # they sit until the job runs and after it fails — so an s3 target, which is a bucket plus
    # the credentials to reach it, must never be one. The job resolves FileLayer.current instead,
    # from the same validated ENV the fan-out read.
    test "the s3 fan-out puts no bucket and no credentials in the job payload" do
      user!
      with_env(S3_ENV) do
        Library::ScanJob.scan_all!
        args = enqueued_jobs.last["arguments"].first
        assert_equal [ "user_id" ], args.keys.grep_v(/_aj_/),
                     "an s3 scan job names only the user — the target comes from the deployment"
      end
    end

    # The other half of the trap: a gate that enqueues a job that does nothing is no better than a
    # gate that enqueues nothing. This drives the REAL observer against a REAL Aws::S3::Client
    # (FakeS3 stubs the transport, not the SDK) and asserts a row lands.
    test "a scan with no root indexes the deployment's s3 bucket" do
      fake = FakeS3.new
      user = user!
      fake.seed!("library/j.stl", "bytes")

      with_injected_s3(fake) do
        Library::ScanJob.perform_now(user_id: user.id)
      end

      assert user.nodes.find_by(storage_path: "j.stl"), "the scan must index the object"
    end

    # A chunk deployment has no store to poll, so a rootless scan has nothing to do — but it must
    # SAY so rather than no-op. `perform` is a command: the one thing it may never do is silently
    # nothing (that is the failure this whole task exists to remove, and putting it back here
    # would just relocate it from scan_all! to perform).
    test "a rootless scan on a non-scannable backend raises rather than silently doing nothing" do
      user = user!
      with_env("LIBRARY_BACKEND" => "chunk_remote",
               "CHUNK_REMOTE_URL" => "http://sync.invalid",
               "SYNC_ADMIN_TOKEN" => "test-token",
               "SYNC_PUBLIC_URL" => "http://sync.invalid") do
        err = assert_raises(ArgumentError) { Library::ScanJob.perform_now(user_id: user.id) }
        assert_match(/not a scanned backend/, err.message)
      end
    end

    # THE ONE HONEST "A SCAN FINISHED" MARKER (stage 4, S4-3). The browser polls this through
    # /files/scan_status, so what it means matters: a pass that completed, INCLUDING the discovery
    # and intake steps whose results the reloaded page is expected to show.
    test "a completed scan stamps when it finished" do
      Dir.mktmpdir do |dir|
        user = user!
        File.binwrite(File.join(dir, "j.stl"), "bytes")
        assert_nil user.library_scanned_at, "nothing has scanned for a fresh user"

        travel_to Time.utc(2026, 9, 7, 12, 0, 0) do
          Library::ScanJob.perform_now(user_id: user.id, root: dir)
        end

        assert_equal Time.utc(2026, 9, 7, 12, 0, 0), user.reload.library_scanned_at
      end
    end

    # A REFUSAL IS NOT A FINISH, AND THE POLLER MUST NOT BE TOLD IT WAS. Library::Scanner::UnsafeScan
    # is the reconcile declining (a missing root, a mass-deletion trip); the catalog is untouched, so
    # a stamp here would send every watching page into a reload showing nothing new and reading as
    # "the scan worked". The failed-jobs row is the report (this job's own header), and the browser
    # gives up with a neutral sentence instead.
    test "a refused scan stamps nothing" do
      user = user!

      assert_raises(Library::Scanner::UnsafeScan) do
        Library::ScanJob.perform_now(user_id: user.id, root: "/nonexistent-#{SecureRandom.hex(4)}")
      end

      assert_nil user.reload.library_scanned_at
    end

    # THE REFUSAL IS WRITTEN DOWN WHERE THE PAGE CAN READ IT (K §5), and the next scan that works
    # takes it back: /settings/library shows `library_scan_refusal` with its next step, so a stale one
    # would go on telling the owner their folder was refused after it had scanned.
    test "a refused scan records why, and the next scan that succeeds clears it" do
      Dir.mktmpdir do |dir|
        user = user!

        assert_raises(Library::Scanner::UnsafeScan) do
          Library::ScanJob.perform_now(user_id: user.id, root: "/nonexistent-#{SecureRandom.hex(4)}")
        end
        assert_match(/is missing/, user.reload.library_scan_refusal)

        Library::ScanJob.perform_now(user_id: user.id, root: dir)
        assert_nil user.reload.library_scan_refusal
      end
    end

    # --- a scan queued before the library folder changed (K §5) ----------------------------------
    #
    # The adapter is over the NEW folder and old.stl exists only in the OLD one, so a scan that
    # indexes it ran on the folder the library left. A DAY separates the setting's write from the
    # enqueue on purpose: two stamps a moment apart pass whichever way the comparison runs (§15).
    # perform_enqueued_jobs, not perform_now, because only a job that went through the queue carries
    # an `enqueued_at`.
    test "a scan queued before the library folder changed is discarded, not run on the old folder" do
      with_moved_library do |old_root, _new_root|
        user = user!
        travel_to(2.days.ago) { Library::ScanJob.perform_later(user_id: user.id, root: old_root) }
        travel_to(1.day.ago) { Setting.put(Tinkerex::LibraryRoot::KEY, "new-root") }

        log = capture_log { perform_enqueued_jobs(only: Library::ScanJob) }

        assert_nil user.nodes.find_by(storage_path: "old.stl"), "the queued scan ran on the folder the library left"
        assert_match(/discarding a scan of #{Regexp.escape(old_root)} queued before/, log,
                     "the discard must say which root it dropped")
      end
    end

    test "a scan queued after the library folder changed runs on the root it names" do
      with_moved_library do |old_root, _new_root|
        user = user!
        travel_to(1.day.ago) { Setting.put(Tinkerex::LibraryRoot::KEY, "new-root") }
        Library::ScanJob.perform_later(user_id: user.id, root: old_root)

        perform_enqueued_jobs(only: Library::ScanJob)

        assert user.nodes.find_by(storage_path: "old.stl"),
               "a job queued after the change was judged stale: the enqueued_at comparison is gone"
      end
    end

    # The same folder written twice (a confirm clicked again) moves the timestamp and not the root.
    test "a scan queued before a write that left the root in place still runs" do
      with_moved_library do |_old_root, new_root|
        File.binwrite(File.join(new_root, "new.stl"), "n")
        user = user!
        travel_to(2.days.ago) { Library::ScanJob.perform_later(user_id: user.id, root: new_root) }
        travel_to(1.day.ago) { Setting.put(Tinkerex::LibraryRoot::KEY, "new-root") }

        perform_enqueued_jobs(only: Library::ScanJob)

        assert user.nodes.find_by(storage_path: "new.stl"), "a queued scan of the CURRENT root was discarded"
      end
    end

    # The command contract (#perform's header) survives the change: perform_now has no enqueued_at.
    test "perform_now still scans the root it names after the library folder changed" do
      with_moved_library do |old_root, _new_root|
        user = user!
        travel_to(1.day.ago) { Setting.put(Tinkerex::LibraryRoot::KEY, "new-root") }

        Library::ScanJob.perform_now(user_id: user.id, root: old_root)

        assert user.nodes.find_by(storage_path: "old.stl"), "an explicitly commanded scan was discarded"
      end
    end

    private

    # Two folders and a Share adapter over the second, which is the library's folder after a change.
    def with_moved_library
      old_root = Dir.mktmpdir("old-root")
      new_root = Dir.mktmpdir("new-root")
      File.binwrite(File.join(old_root, "old.stl"), "o")
      FileLayer.current = FileLayer::Share.new(root: new_root)
      yield old_root, new_root
    ensure
      FileLayer.reset!
      [ old_root, new_root ].each { |d| FileUtils.remove_entry(d) if d && File.exist?(d) }
    end

    # FileLayer.current= rather than ENV, because the fake CLIENT has to be injected and the
    # ENV-based idioms rebuild from ENV (FileLayer.build constructs a real client). Prior art:
    # file_bytes_test.rb:30.
    #
    # THE ensure IS LOAD-BEARING. A direct `FileLayer.current =` does NOT set test_helper's
    # @file_layer_backend_pinned, so its teardown will not clean up after this — without the
    # reset! the adapter leaks into the next test in this forked worker and fails there as
    # something unrelated, a whole debugging session away from the cause.
    def with_injected_s3(fake)
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", prefix: "library",
                                            client: fake.client)
      yield
    ensure
      FileLayer.reset!
    end

    # The three knobs LibraryBackendCheck requires for s3 (region/endpoint/prefix are optional).
    # Frozen at parse time rather than built per test: these are constants of the deployment
    # shape, not fixtures.
    S3_ENV = {
      "LIBRARY_BACKEND" => "s3", "LIBRARY_S3_BUCKET" => "b",
      "LIBRARY_S3_ACCESS_KEY_ID" => "ak", "LIBRARY_S3_SECRET_ACCESS_KEY" => "sk"
    }.freeze

    def user!
      User.create!(email: "job-#{SecureRandom.hex(6)}@example.com")
    end

    # Nil deletes the key, which is the operator-forgot-to-set-it case. Mirrors factory_test's
    # with_backend/with_library_path; FileLayer is reset so the memoized adapter cannot leak the
    # previous test's backend into this one.
    def with_env(vars)
      prior = vars.keys.index_with { |k| ENV[k] }
      vars.each { |k, v| ENV[k] = v }
      FileLayer.reset!
      yield
    ensure
      prior.each { |k, v| ENV[k] = v }
      FileLayer.reset!
    end

    def capture_log
      io = StringIO.new
      prior = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = prior
    end
  end

  # The project-folder intake runs at the END of #perform. ORDER IS A CORRECTNESS CONSTRAINT, not
  # tidiness — see Maker::ProjectIntake and the spec's §5.
  #
  # PROVED BY EFFECT, NOT BY CALL-ORDER RECORDING, and that is deliberate on two counts. `stub`
  # does not exist in this suite (minitest 6 dropped minitest/mock — see
  # test/jobs/maker/generate_preview_job_test.rb's forcing_available), and more importantly a
  # recorded order would assert the implementation rather than the guarantee. Here the file
  # exists ONLY on disk: the intake can only attach a node the reconcile has already created, so
  # an attachment at the end of one #perform IS the proof that the reconcile ran first.
  #
  # A SIBLING OF ScanJobTest, NOT A SUBCLASS — deliberately, even though it wants that class's
  # `user!` one-liner. Subclassing `< ScanJobTest` was tried first: Minitest registers every
  # subclass of a TestCase as its own runnable, so it re-ran all 13 of the parent's tests a
  # SECOND time under the child's name (28 runs instead of 15) — each preceded by this class's
  # own setup building a Share root and a project folder that those inherited test bodies never
  # look at. Harmless in outcome, pure waste in the suite, and not this codebase's idiom for
  # sharing test logic: the adapter contracts (test/services/file_layer/adapter_contract.rb) do
  # that with a MODULE included into each concrete test case, never by inheriting one concrete
  # `*Test` class from another. So this repeats the one line of setup instead.
  class IntakeOrderTest < ActiveSupport::TestCase
    setup do
      @root = Dir.mktmpdir
      @user = User.create!(email: "job-#{SecureRandom.hex(6)}@example.com")
      # A Share adapter rooted at @root, so ensure_library_folder! below goes through the PORT's
      # mkdir (port_writable? true) and stamps a real storage_path under @root, AND so the intake's
      # own file move (Maker::MoveNode -> FileLayer.current.move) lands on the same directory the
      # scan just read. Chunk mode's mkdir never touches disk and leaves storage_path nil — the
      # file below needs a real on-disk parent to be written into.
      FileLayer.current = FileLayer::Share.new(root: @root)

      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
      # A file that exists on disk and in NO node row — "someone drops a file on the NAS in
      # Finder". Path must match the folder's storage_path. The mkdir_p is usually a no-op (the
      # port_mkdir above already created the directory); it is here so this setup does not depend
      # on that and still reads correctly if the fixture's root is recreated.
      FileUtils.mkdir_p(File.join(@root, @folder.storage_path))
      File.binwrite(File.join(@root, @folder.storage_path, "panel.svg"), "<svg/>")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    test "one perform indexes the file AND attaches and files it" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      att = @project.file_attachments.sole
      node = @user.nodes.find_by!(node_id: att.node_id)
      assert_equal "panel.svg", node.name
      assert_equal "vector", att.role
      assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name,
                   "the intake ran after the reconcile — it filed a node the reconcile created"
    end

    # THE FINDING THIS PINS: intake_project_folders used to call Maker::ProjectIntake.for_user
    # directly and throw its RunResult away, so a cap refusal reached via a scan-triggered intake
    # logged NOTHING — reproduced by forcing PROJECT_ORGANIZE_MAX_MOVES=1 against two loose files
    # and finding no match anywhere in the log for /cap/i, /refus/i or /attached/i. The identical
    # trip on a chunk deployment (Maker::ProjectIntakeJob#report) already warns — see
    # project_intake_job_test.rb's "the cap refusal is logged", same wording, same regex, driven
    # through Library::ScanJob here instead of Maker::ProjectIntakeJob directly, because that is
    # the path this finding was about. There is no shared capture_log helper reachable from this
    # sibling class (see the class comment above), so this inlines it exactly as
    # project_intake_job_test.rb's own version of this test does.
    test "a cap refusal reached via the scan is logged, identically to the scheduled sweep" do
      # A second loose file: two loose files trip a cap of 1 (setup already staged "panel.svg").
      File.binwrite(File.join(@root, @folder.storage_path, "second.svg"), "<svg/>")

      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = "1"
      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      begin
        Library::ScanJob.perform_now(user_id: @user.id, root: @root)
      ensure
        Rails.logger = original_logger
        ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
      end

      assert_match(/REFUSED to file 2 loose files for user #{@user.id} — over the 1 cap/, log.string)
    end

    # THE MODEL CATALOG RUNS TOO, AND AFTER THE PROJECT INTAKE — proved by EFFECT, like the test
    # above.
    #
    # `bracket.stl` exists only on disk, so a model keyed on it at all is proof the reconcile ran
    # first. WHICH model it is proves the rest: loose at `Projects/desk-lamp/`, the seeded `*` shelf
    # makes the project's own folder its key; the intake then files it into
    # `Projects/desk-lamp/models/`, under the seeded `Projects/*/models` shelf, where it is its own
    # model titled "bracket".
    #
    # MUTATION-CHECKED: moving intake_models(user) above intake_project_folders(user) in
    # Library::ScanJob#perform turns this RED with [] — re-measured 2026-10-19 (F-S07-1).
    #
    # THAT VALUE HAS MOVED THREE TIMES, AND THIS COMMENT TRAILED EVERY MOVE. ["Projects"] until
    # `Maker::Shelf::SEEDS` gained `"*"` (re-measured 2026-08-26); then ["desk-lamp"], the project's
    # whole folder as one model nothing reaps, until the catalog began dropping a folder a project
    # claims (2026-09-02). Since then the key it would mint is CLAIMED, so the swap catalogues
    # nothing at the old path and the model arrives a scan late: under `Projects/` this ordering
    # changes the TIMING, not the answer — and a folder discovery has not adopted yet is claimed by
    # position too (F-S07-1). It still changes the ANSWER where a project's root is itself a shelf;
    # Library::ScanJob#intake_models has that case, which this test does not reach.
    test "cataloguing runs after the project intake, so a filed file is its own model" do
      File.binwrite(File.join(@root, @folder.storage_path, "bracket.stl"), "solid")

      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_equal [ "bracket" ], @user.maker_models.pluck(:title),
                   "no model, or one not titled after the file, means the catalog ran BEFORE the " \
                   "intake moved bracket.stl: still loose at the project root, it keyed to the " \
                   "project's claimed folder, so it was left for a later scan"
      model = @user.maker_models.sole
      node = @user.nodes.find_by!(node_id: model.auto_node_id)
      assert_equal "models", @user.nodes.find_by(node_id: node.parent_node_id).name
      assert_equal [ node.node_id ], model.file_attachments.pluck(:node_id),
                   "the attachment must point at the node THIS scan created"
    end

    # THE SAME PROMISE FOR PROJECT DISCOVERY, and it needs its own test rather than riding either
    # rescue below: the three are separate, and #discover_projects is the FIRST of them — it runs
    # immediately after the reconcile and strictly before the project intake — so a raise there is
    # the one an operator reading the failed-jobs table is likeliest to mistake for "the reconcile
    # itself failed."
    #
    # ALSO PINS THAT THE RAISE REACHES THAT RESCUE THROUGH THE JOB WRAPPER. #discover_projects
    # calls Maker::ProjectDiscoveryJob.perform_now, and ActiveJob is entitled to swallow or
    # re-raise on its own terms (its discard_on covers RecordNotFound); a RuntimeError must arrive
    # at the rescue that logs it.
    test "a project discovery failure does not fail a scan that already succeeded" do
      original = Maker::ProjectDiscovery.method(:for_user)
      Maker::ProjectDiscovery.define_singleton_method(:for_user) { |**| raise "discovery exploded" }
      begin
        log = nil
        prior = Rails.logger
        io = StringIO.new
        Rails.logger = Logger.new(io)
        begin
          assert_nothing_raised { Library::ScanJob.perform_now(user_id: @user.id, root: @root) }
        ensure
          log = io.string
          Rails.logger = prior
        end

        assert @user.nodes.present.exists?(name: "panel.svg"),
               "the reconcile's work stands — it committed before discovery ran"
        assert_match(/project discovery failed for user #{@user.id}: RuntimeError: discovery exploded/,
                     log, "the swallowed failure must still be written down somewhere")
      ensure
        Maker::ProjectDiscovery.define_singleton_method(:for_user, original)
      end
    end

    # A scan that SUCCEEDED must not be reported as failed because the intake blew up. The
    # reconcile is already committed (there is no transaction), so an operator reading a failed
    # ScanJob would conclude the library did not index — which would be false.
    #
    # Hand-rolled override with an ensure-restore, the forcing_available idiom from
    # generate_preview_job_test.rb. The ensure is load-bearing: a leaked override would make
    # every later test in this process see a broken intake.
    test "an intake failure does not fail a scan that already succeeded" do
      original = Maker::ProjectIntake.method(:for_user)
      Maker::ProjectIntake.define_singleton_method(:for_user) { |**| raise "intake exploded" }
      begin
        assert_nothing_raised { Library::ScanJob.perform_now(user_id: @user.id, root: @root) }
        assert @user.nodes.present.exists?(name: "panel.svg"),
               "the reconcile's work stands — it committed before the intake ran"
      ensure
        Maker::ProjectIntake.define_singleton_method(:for_user, original)
      end
    end

    # THE SAME PROMISE FOR THE CATALOG, and it needs its own test rather than riding the one above:
    # the rescues are separate, and deleting the one in #intake_models left every test in the
    # repo green until this existed. The catalog runs LAST, so a raise there is the likeliest of
    # the three to be mistaken for "the scan failed" by an operator reading the failed-jobs table.
    #
    # ALSO PINS THAT THE RAISE REACHES THAT RESCUE THROUGH THE JOB WRAPPER. #intake_models calls
    # Maker::ModelIntakeJob.perform_now, and ActiveJob is entitled to swallow or re-raise on its
    # own terms (its discard_on covers RecordNotFound); a RuntimeError must arrive at the rescue
    # that logs it.
    test "a model catalog failure does not fail a scan that already succeeded" do
      original = Maker::ModelIntake.method(:for_user)
      Maker::ModelIntake.define_singleton_method(:for_user) { |**| raise "catalog exploded" }
      begin
        log = nil
        prior = Rails.logger
        io = StringIO.new
        Rails.logger = Logger.new(io)
        begin
          assert_nothing_raised { Library::ScanJob.perform_now(user_id: @user.id, root: @root) }
        ensure
          log = io.string
          Rails.logger = prior
        end

        assert @user.nodes.present.exists?(name: "panel.svg"),
               "the reconcile's work stands — it committed before the catalog ran"
        assert @project.file_attachments.any?,
               "and so does the project intake's, which also ran before it"
        assert_match(/model catalog failed for user #{@user.id}: RuntimeError: catalog exploded/,
                     log, "the swallowed failure must still be written down somewhere")
      ensure
        Maker::ModelIntake.define_singleton_method(:for_user, original)
      end
    end
  end

  # A GIT WORKING TREE UNDER `Projects/` IS ADOPTED AS A PROJECT AND ITS BYTES ARE LEFT ALONE, and
  # nothing pinned that combination until this class. Both halves already had guards — discovery's
  # dot rule in project_discovery_test.rb, `:in_working_tree` in attach_to_project_test.rb — but the
  # behaviour a user actually gets is their COMPOSITION, which held by luck rather than by contract.
  # This repo's recorded failure shape is exactly that: two correct halves and nothing asserting the
  # seam (§14e's "the suite being green is not evidence a guard works").
  #
  # WHAT MAKES IT WORTH A TEST RATHER THAN A COMMENT: the intake sweep's whole job is to move loose
  # files at a project root into category subfolders, and doing that to a tracked file is a delete
  # plus an untracked add as far as git is concerned. Maker::AttachToProject's `:in_working_tree`
  # is the only thing standing between the sweep and someone's repository, it is detected purely by
  # the `.git` MARKER NODE surviving the scan (Library::RepoMetadata), and discovery now hands the
  # sweep project folders it never had before. Three independent mechanisms, one outcome.
  class GitWorkingTreeTest < ActiveSupport::TestCase
    setup do
      @root = Dir.mktmpdir
      @user = User.create!(email: "job-#{SecureRandom.hex(6)}@example.com")
      FileLayer.current = FileLayer::Share.new(root: @root)

      # A repo checked out UNDER Projects/, on disk only — no project row, no node rows.
      FileUtils.mkdir_p(File.join(@root, "Projects", "my-firmware", ".git"))
      File.binwrite(File.join(@root, "Projects", "my-firmware", ".git", "HEAD"), "ref: refs/heads/main\n")
      File.binwrite(File.join(@root, "Projects", "my-firmware", "README.md"), "# firmware\n")
      File.binwrite(File.join(@root, "Projects", "my-firmware", "bracket.stl"), "solid")

      # And a repo checked out AT the Projects root — the case discovery's dot rule exists for.
      FileUtils.mkdir_p(File.join(@root, "Projects", ".git"))
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    def firmware_dir = @user.nodes.present.find_by!(name: "my-firmware", kind: "dir")

    test "the repo is adopted as a project and its files are attached" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      project = @user.maker_projects.sole
      assert_equal "my-firmware", project.name
      assert_equal firmware_dir.node_id, project.folder_node_id
      assert_equal %w[bracket.stl README.md].sort,
                   project.file_attachments.map { |a| @user.nodes.find_by(node_id: a.node_id)&.name }.sort
    end

    # THE HALF THAT PROTECTS THE REPOSITORY. `:in_working_tree` means "attach the row, leave the
    # bytes", so the attach above must happen AND nothing may move.
    test "no file is moved and no category subfolder is minted" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      %w[README.md bracket.stl].each do |name|
        assert_path_exists File.join(@root, "Projects", "my-firmware", name)
      end
      # `models` is where bracket.stl WOULD go, and `docs` is where README.md would — naming the two
      # the fixture can actually produce, rather than asserting over a list that would still pass if
      # ProjectFolders grew a category tomorrow.
      %w[models docs].each do |cat|
        assert_nil @user.nodes.present.find_by(parent_node_id: firmware_dir.node_id, name: cat,
                                               kind: "dir"),
                   "the intake minted #{cat}/ inside a git working tree — :in_working_tree did not hold"
      end
    end

    # THE MARKER SURVIVES AND ITS CONTENTS DO NOT. Both halves matter: delete the marker and
    # `:in_working_tree` has nothing to detect (the test above starts passing for the wrong reason,
    # then failing for the right one); index the contents and a repo's whole object store lands in
    # the library. Library::RepoMetadata's header calls this asymmetry the design.
    test "the .git marker is indexed and its contents are not" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      marker = @user.nodes.present.find_by(parent_node_id: firmware_dir.node_id, name: ".git",
                                           kind: "dir")
      refute_nil marker, "the marker must survive the scan — it is the only evidence of a working tree"
      assert_equal 0, @user.nodes.present.where(parent_node_id: marker.node_id).count
    end

    # A REPO AT THE `Projects/` ROOT IS NOT A PROJECT. Without discovery's dot rule this mints one
    # titled ".git", because `.git` keeps its node where every other skip removes the entry (§14b).
    test "a repo checked out at the Projects root is not adopted" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_equal [ "my-firmware" ], @user.maker_projects.pluck(:name),
                   "a project named .git means the dot rule stopped covering the marker"
    end
  end

  # DISCOVERY RUNS AFTER THE RECONCILE AND BEFORE THE FILING SWEEP, so ONE perform adopts a folder,
  # files its loose files and catalogues what it filed. This drives the whole feature end to end
  # through the only door a share deployment has: someone makes Projects/Desk Lamp/ in Finder and
  # drops a file in it. SINCE F-S07-1 (2026-10-19) NO ORDERING CAN MAKE A FOLDER ONE MODEL: the
  # catalog counts a folder discovery owns by position as claimed, so the order decides what one
  # pass achieves, and the last test pins the not-swallowed half against discovery's cap instead.
  class DiscoveryOrderTest < ActiveSupport::TestCase
    setup do
      @root = Dir.mktmpdir
      @user = User.create!(email: "job-#{SecureRandom.hex(6)}@example.com")
      # A Share adapter rooted at @root, so the intake's own move (Maker::MoveNode ->
      # FileLayer.current.move) lands on the same directory the scan just read.
      FileLayer.current = FileLayer::Share.new(root: @root)

      # ON DISK ONLY — no project row, no node rows. This is the feature's whole subject.
      FileUtils.mkdir_p(File.join(@root, "Projects", "Desk Lamp"))
      File.binwrite(File.join(@root, "Projects", "Desk Lamp", "panel.svg"), "<svg/>")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    test "one perform discovers the project AND attaches and files its loose file" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      project = @user.maker_projects.sole
      assert_equal "Desk Lamp", project.name
      assert_equal "desk-lamp", project.slug

      att = project.file_attachments.sole
      node = @user.nodes.find_by!(node_id: att.node_id)
      assert_equal "panel.svg", node.name
      assert_equal "vector", att.role
      assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name,
                   "discovery ran BEFORE the project intake — the intake filed a folder that " \
                   "discovery had only just adopted. Swap the two calls in ScanJob#perform and " \
                   "this goes red earlier, at `project.file_attachments.sole` above: with no " \
                   "project row yet when the intake runs, it has nothing to sweep, so panel.svg " \
                   "is never attached or filed at all. (`panel.svg` is role \"vector\", never " \
                   "MODEL-role, so it says nothing about the model catalog — the two model-role " \
                   "tests below do.)"
    end

    # THE CATEGORY FOLDER GOES UNDER THE FOLDER THE USER MADE, not a second `Projects/desk-lamp/`
    # tree rebuilt from the slug. See Task 3 — this is that fix, driven through the real door.
    test "the category folder is created under the discovered folder, not a slug-named twin" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_path_exists File.join(@root, "Projects", "Desk Lamp", "design", "panel.svg")
      refute File.exist?(File.join(@root, "Projects", "desk-lamp")),
             "no second Projects/<slug> tree may be minted"
    end

    # A DISCOVERED PROJECT'S MESH IS FILED AND CATALOGUED IN THE SAME PERFORM. `panel.svg` above is
    # role "vector", so Maker::ModelIntake.classify never looks at it; `bracket.stl` it does.
    # `Projects/` is a shelf (the seeded `*`) and `Desk Lamp` is not, so while bracket.stl is loose
    # at the folder's root its key is the folder; one intake later it sits under the seeded
    # `Projects/*/models` shelf and is its own model, titled "bracket".
    #
    # THE ORDER NOW DECIDES WHEN, NOT WHETHER (F-S07-1, 2026-10-19). This test used to assert first
    # that the WHOLE `Desk Lamp` folder never became one model — what a catalog reaching an
    # unadopted folder left behind, permanently — and its comment said that assertion was "verified
    # against BOTH" #perform mutations below. That stopped being true when the catalog began
    # dropping a folder a project claims (2026-09-02): measured on the code just before this change,
    # the discover/intake swap left it green and only the reconcile mutation reached it. Since the
    # catalog also counts a folder discovery owns BY POSITION, NO ordering reaches it — measured,
    # all four below left it green — and a guard that cannot fail is §15's vacuous shape. So it
    # moved to the next test, where discovery's cap still puts an unadopted folder in front of the
    # catalog. These two assertions are what every ordering mutation of #perform now fails, each
    # measured:
    #   discover_projects swapped with intake_project_folders -> the path (nothing filed);
    #   discover_projects moved above observer.call          -> the path (nothing adopted);
    #   intake_models moved above discovery, or above the intake -> the titles, with [] — nothing
    #     catalogued at the old path, because its key is a claimed folder; the next scan would.
    test "one perform files the discovered project's mesh AND catalogues it as its own model" do
      File.binwrite(File.join(@root, "Projects", "Desk Lamp", "bracket.stl"), "solid")

      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_path_exists File.join(@root, "Projects", "Desk Lamp", "models", "bracket.stl"),
                          "discovery ran before the intake, so the intake had a project folder to file this into"
      assert_equal [ "bracket" ], @user.maker_models.pluck(:title),
                   "the catalog ran before the intake filed bracket.stl, so it is catalogued a scan late"
    end

    # THE SWALLOW ASSERTION, RE-POINTED (F-S07-1) from the test above, where no ordering of #perform
    # can fail it any more. Discovery's CAP binds inside this job's own sequence, so with
    # PROJECT_DISCOVERY_MAX=1 one of these two folders is necessarily still unadopted — its mesh
    # loose at its root — when #intake_models runs: the state the old assertion guarded, reached the
    # one way that is left. Which folder depends on the node_ids the reconcile mints, so the test
    # finds it rather than naming it, and asserts that precondition before the claim: without a
    # folder left waiting, "nothing was swallowed" proves nothing (§14e). RED when Maker::ModelIntake
    # stops asking Maker::ProjectDiscovery.positional_claims, or when that reader is capped.
    test "a folder past discovery's cap is never swallowed as one model" do
      File.binwrite(File.join(@root, "Projects", "Desk Lamp", "bracket.stl"), "solid")
      FileUtils.mkdir_p(File.join(@root, "Projects", "Rack"))
      File.binwrite(File.join(@root, "Projects", "Rack", "rail.stl"), "solid rail")
      prior = ENV["PROJECT_DISCOVERY_MAX"]
      ENV["PROJECT_DISCOVERY_MAX"] = "1"
      begin
        Library::ScanJob.perform_now(user_id: @user.id, root: @root)
      ensure
        ENV["PROJECT_DISCOVERY_MAX"] = prior
      end

      folders = @user.nodes.present.where(parent_node_id: @user.nodes.present
                                            .find_by!(name: "Projects", parent_node_id: nil).node_id,
                                          kind: "dir").to_a
      adopted = @user.maker_projects.pluck(:folder_node_id)
      waiting = folders.reject { |f| adopted.include?(f.node_id) }
      assert_equal [ 2, 1, 1 ], [ folders.size, adopted.size, waiting.size ],
                   "precondition: the cap must leave exactly one of the two folders unadopted"
      assert(@user.nodes.present.where(parent_node_id: waiting.sole.node_id, kind: "file")
                  .pluck(:name).any? { |name| Maker::FileAttachment.role_for(name) == "model" },
             "precondition: the unadopted folder still holds a mesh at its root")

      ids = folders.map(&:node_id)
      swallowed = @user.maker_models.where(auto_node_id: ids)
                       .or(@user.maker_models.where(folder_node_id: ids)).pluck(:title)
      assert_empty swallowed,
                   "#{waiting.sole.name.inspect}, past discovery's cap, became one model: the catalog " \
                   "no longer counts a folder discovery owns by position as claimed"
    end
  end

  # .enqueue_for is the ONE place that decides which args may be serialized into the queue's
  # database. Extracted from .scan_all! when Projects::ScansController became a second caller:
  # an S3 library's target is a bucket plus credentials and must never be written there, so a
  # second copy of that branch is exactly the drift CLAUDE.md warns about.
  class ScanJobEnqueueForTest < ActiveJob::TestCase
    setup { @user = User.create!(email: "ef-#{SecureRandom.hex(4)}@example.com",
                                 password: "correct horse battery staple", confirmed_at: Time.current) }
    teardown { FileLayer.reset! }

    test "a share library enqueues WITH its root, which is a path and safe to serialize" do
      root = Dir.mktmpdir("enqueue-for")
      FileLayer.current = FileLayer::Share.new(root:)
      assert_enqueued_with(job: Library::ScanJob,
                           args: [ { user_id: @user.id, root: root } ]) do
        Library::ScanJob.enqueue_for(@user)
      end
    ensure
      FileUtils.remove_entry(root) if root && File.exist?(root)
    end

    test "an s3 library enqueues with NO root — a bucket plus credentials must not reach the queue" do
      require_relative "../../support/fake_s3"
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", client: FakeS3.new.client)
      assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id } ]) do
        Library::ScanJob.enqueue_for(@user)
      end
    end
  end

  # ONE SCAN, ONE LIBRARY FOLDER (K, 2026-10-20; found in review). The walk uses the `root:` the job
  # was queued with, while the intake after it writes through FileLayer.current, whose share root is
  # read per job (FileLayer::Share#root). Unpinned, the job's FIRST read of the setting came after the
  # walk, so a folder chosen in the web process mid-walk sent the intake into the NEW folder: it
  # minted `Workshop/Projects/Desk Lamp/design` there and then failed the move. The write is made
  # behind this process's back right after the walk, and Current is cleared first, as the executor
  # does before a real job. Pinned through the real factory (LIBRARY_BACKEND=share), so it runs the
  # same on every leg. Mutation-checked: delete the pin in #perform and both assertions go red.
  class FolderChangeMidScanTest < ActiveSupport::TestCase
    setup do
      @mount = Pathname.new(Dir.mktmpdir("mid-scan")).expand_path
      @prior = ENV.to_h.slice("LIBRARY_PATH", "LIBRARY_BACKEND")
      ENV["LIBRARY_PATH"] = @mount.to_s
      ENV["LIBRARY_BACKEND"] = "share"
      FileLayer.reset!
      @user = User.create!(email: "mid-#{SecureRandom.hex(6)}@example.com")
      FileUtils.mkdir_p(@mount.join("Projects", "Desk Lamp"))
      File.binwrite(@mount.join("Projects", "Desk Lamp", "panel.svg"), "<svg/>")
      FileUtils.mkdir_p(@mount.join("Workshop"))
    end

    teardown do
      %w[LIBRARY_PATH LIBRARY_BACKEND].each { |k| @prior.key?(k) ? ENV[k] = @prior[k] : ENV.delete(k) }
      FileLayer.reset!
      FileUtils.remove_entry(@mount) if @mount&.exist?
    end

    test "a folder chosen while a scan walks is the next job's, never this scan's intake" do
      original = Library::Scanner.instance_method(:call)
      begin
        Library::Scanner.define_method(:call) do
          result = original.bind(self).call
          Setting.where(key: Tinkerex::LibraryRoot::KEY).update_all(value: "Workshop")
          result
        end
        Current.reset
        Library::ScanJob.perform_now(user_id: @user.id, root: @mount.to_s)
      ensure
        Library::Scanner.define_method(:call, original)
      end

      assert_not @mount.join("Workshop", "Projects").exist?,
                 "the intake filed into the folder the library moved to while the scan walked"
      assert_path_exists @mount.join("Projects", "Desk Lamp", "design", "panel.svg")
    end
  end
end
