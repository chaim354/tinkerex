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
               "SYNC_ADMIN_TOKEN" => "test-token") do
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
               "SYNC_ADMIN_TOKEN" => "test-token") do
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
               "SYNC_ADMIN_TOKEN" => "test-token") do
        err = assert_raises(ArgumentError) { Library::ScanJob.perform_now(user_id: user.id) }
        assert_match(/not a scanned backend/, err.message)
      end
    end

    private

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
    # above, because what the swap changes is the ANSWER and not merely the timing.
    #
    # `bracket.stl` exists only on disk, so a model keyed on it at all is proof the reconcile ran
    # first. WHICH model it is proves the rest: a file loose at `Projects/desk-lamp/` has no shelf
    # nearer than the library root (one of Maker::Shelf::SEEDS), so the nearest-shelf rule makes
    # the whole `Projects` FOLDER its model, titled "Projects". The project intake then files it
    # into `Projects/desk-lamp/models/`, under the seeded `Projects/*/models` shelf, where it is
    # its own model titled "bracket". Run the catalog first and the sweep mints "Projects" in the
    # same job that is about to make that false — and nothing later removes it, because an auto
    # model is only ever created, never reaped.
    #
    # MUTATION-CHECKED: moving intake_models(user) above intake_project_folders(user) in
    # Library::ScanJob#perform turns this RED with ["desk-lamp"].
    #
    # THAT VALUE USED TO BE ["Projects"], AND THE COMMENT WENT ON SAYING SO AFTER IT STOPPED BEING
    # TRUE — re-measured 2026-08-26. `Maker::Shelf::SEEDS` gained `"*"` (every top-level folder is
    # a shelf), which moves the swallowed-model boundary one level DOWN: `Projects` is now itself a
    # shelf, so the folder that gets swallowed is the project's own `desk-lamp`, not `Projects`.
    # The hazard is unchanged and the test still pins it; only the name it comes back under moved.
    test "cataloguing runs after the project intake, so a filed file is its own model" do
      File.binwrite(File.join(@root, @folder.storage_path, "bracket.stl"), "solid")

      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_equal [ "bracket" ], @user.maker_models.pluck(:title),
                   "a model titled after the PROJECT FOLDER (desk-lamp) rather than the file " \
                   "means the catalog ran BEFORE the intake moved it: the file was still loose " \
                   "at the project root, whose nearest shelf is `Projects` itself, so the whole " \
                   "folder became one model"
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

  # THE GIT COMMIT PASS RUNS AT THE END OF #perform, STRICTLY AFTER THE PROJECT INTAKE, and the
  # ordering changes the HISTORY rather than the timing — which is what makes it a correctness
  # constraint of the same kind as #intake_models' above rather than a preference.
  #
  # THE INTAKE MOVES FILES. A commit taken before it records every loose file at the path this same
  # job is about to abandon; the next tick records it again at its real path, so one change becomes
  # TWO commits and the first describes a layout that no longer exists. Git keeps whatever it was
  # told, so no later pass repairs it — the wrong path is in the history permanently, exactly the
  # way an auto model minted at the wrong shelf is permanent one method up.
  #
  # PROVED BY EFFECT, NOT BY CALL-ORDER RECORDING, for IntakeOrderTest's two reasons: `stub` does
  # not exist in this suite, and a recorded order asserts the implementation instead of the
  # guarantee. What is asserted here is the CONTENT of the resulting history, which is the thing a
  # maker actually reads.
  #
  # A SIBLING CLASS RATHER THAN MORE TESTS IN IntakeOrderTest, for that class's own stated reason
  # (Minitest re-runs an inherited TestCase, and this suite shares setup by repetition rather than
  # inheritance) and one of its own: every test here needs MULTIPLE scans, because settle detection
  # means a file is never committed by the scan that first observed it.
  class GitCommitOrderTest < ActiveSupport::TestCase
    setup do
      @root = Dir.mktmpdir
      @user = User.create!(email: "job-#{SecureRandom.hex(6)}@example.com")
      # A Share adapter rooted at @root: the commit pass derives every committed path from
      # storage_path, and Maker::Git::Repo asks the SAME adapter where the repository lives
      # (in place, at <project folder>/.git on share).
      FileLayer.current = FileLayer::Share.new(root: @root)

      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
      FileUtils.mkdir_p(File.join(@root, @folder.storage_path))
      write("panel.svg")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    # THE POSITIVE HALF, and it is not optional: every other test in this class asserts that
    # something did NOT happen, and all of them pass for a commit step that was never wired at all.
    #
    # TWO SCANS, BECAUSE ONE CANNOT COMMIT ANYTHING. The first indexes panel.svg and the intake
    # files it into design/; both writes are inside that scan, so the node is not settled when the
    # pass runs. The second scan is the first one that can see it as quiet.
    test "a settled file is committed at the end of a scan" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      repo = Maker::Git::Repo.for(@project)
      head = repo.head_oid
      assert head, "no commit was recorded — the commit step is not wired into Library::ScanJob#perform"
      # `.svg` is NOT text (Maker::FileAttachment.text?), so Maker::Git::Tracking commits a POINTER
      # naming the library's content hash — asserted at the path the intake filed it to.
      assert_match(/^oid /, repo.blob_at(oid: head, path: "design/panel.svg.ptr"))
    end

    # THE ORDERING ITSELF.
    #
    # THE STAGING IS THE ONLY STATE IN WHICH THE ORDER CHANGES THE ANSWER, and it is worth saying
    # why rather than leaving it to be re-derived: a move BUMPS `updated_at`, so a file the intake
    # files during this scan can never be settled during this scan whichever way round the two are.
    # The ordering bites on a file that is settled AND STILL LOOSE — what a capped tick (or a failed
    # one) leaves behind, and what the intake finally files on some later scan. That is staged here
    # with the cap, exactly as IntakeOrderTest stages its own cap-refusal test.
    #
    # THREE DAYS BACK, NOT THREE SECONDS (§15): a timestamp comparison whose two events land in the
    # same second is a guard that usually cannot fail.
    test "the commit pass runs after the project intake, so a filed file is recorded once, at its filed path" do
      write("second.svg")

      travel_to(3.days.ago) do
        # Two loose files against a cap of one: the intake ATTACHES both and refuses to file either,
        # so both nodes are left at the project root with a three-day-old updated_at.
        with_max_moves("1") { Library::ScanJob.perform_now(user_id: @user.id, root: @root) }
      end
      assert_equal %w[panel.svg second.svg],
                   @user.nodes.present.where(parent_node_id: @folder.node_id, kind: "file")
                        .pluck(:name).sort,
                   "fixture is inverted: the cap did not refuse, so nothing is settled AND loose " \
                   "and this test can no longer tell the two orderings apart"

      Library::ScanJob.perform_now(user_id: @user.id, root: @root) # the intake files both
      Library::ScanJob.perform_now(user_id: @user.id, root: @root) # now they have settled again

      repo = Maker::Git::Repo.for(@project)
      head = repo.head_oid
      assert head, "no commit was recorded — the commit step is not wired into Library::ScanJob#perform"
      assert_equal 1, repo.log(limit: 10).size,
                   "two commits for one change: the pass ran BEFORE the intake, recorded both " \
                   "files at the project root, and recorded them again at their filed paths on " \
                   "the next tick"
      assert repo.blob_at(oid: head, path: "design/panel.svg.ptr")
      assert_raises(FileLayer::NotFound,
                    "the history records panel.svg at the project root — a layout the intake " \
                    "abandoned in the same job that committed it") do
        repo.blob_at(oid: head, path: "panel.svg.ptr")
      end
    end

    # THE ANCHOR IS THE START OF THE SCAN, NOT THE MOMENT THE PASS IS REACHED — the subtle one.
    #
    # Every node this scan touched was written between those two instants: the reconcile creates or
    # updates rows, and the intake moves them. Anchor the pass at `Time.current` where it is called
    # and every one of them reads as SETTLED, which defeats settle detection entirely — a slicer's
    # half-written 200 MB 3MF is committed as a legitimate version on the very scan that first saw
    # it, and a truncated file looks entirely normal afterwards.
    #
    # ASSERTS THE `.git` DIRECTORY TOO, not just the row: an empty `.git` is not inert, it is the
    # MARKER Maker::AttachToProject reads to decide whether §14f filing applies, so a pass that
    # minted one for a project with nothing settled would switch the intake off at the NEXT scan.
    test "a file this scan itself first observed is not committed by this scan" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_nil Maker::GitRepo.find_by(project: @project),
                 "the pass was anchored at the moment it was reached rather than at the start of " \
                 "the scan, so rows this very scan wrote read as settled"
      refute File.exist?(File.join(@root, @folder.storage_path, ".git")),
             "a pass with nothing settled must not mint a .git marker"
    end

    # THE SAME PROMISE THE OTHER THREE POST-RECONCILE STEPS GET, and it needs its own test for the
    # reason #intake_models' version records: the rescues are separate, and deleting one leaves
    # every other test in the repo green. This step runs LAST, so a raise here is the likeliest of
    # the four to be mistaken for "the scan failed" by an operator reading the failed-jobs table.
    #
    # DRIVEN THROUGH THE JOB WRAPPER, DELIBERATELY. Maker::Git::CommitJob already swallows
    # per-PROJECT failures, so what has to reach Library::ScanJob's rescue is the PASS failing —
    # and ActiveJob is entitled to swallow or re-raise on its own terms (its discard_on covers
    # RecordNotFound). A RuntimeError must arrive at the rescue that logs it.
    test "a git commit failure does not fail a scan that already succeeded" do
      original = Maker::Git::CommitJob.instance_method(:perform)
      Maker::Git::CommitJob.define_method(:perform) { |**| raise "commit pass exploded" }
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
               "the reconcile's work stands — it committed before the git pass ran"
        assert @project.file_attachments.any?,
               "and so does the project intake's, which also ran before it"
        assert_match(/git commit pass failed for user #{@user.id}: RuntimeError: commit pass exploded/,
                     log, "the swallowed failure must still be written down somewhere")
      ensure
        Maker::Git::CommitJob.define_method(:perform, original)
      end
    end

    private

    def write(name, body = "<svg/>")
      File.binwrite(File.join(@root, @folder.storage_path, name), body)
    end

    def with_max_moves(value)
      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = value
      yield
    ensure
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
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

  # DISCOVERY RUNS AFTER THE RECONCILE AND BEFORE THE FILING SWEEP, and both orderings change the
  # ANSWER rather than the timing. This drives the whole feature end to end through the only door a
  # share deployment has: someone makes Projects/Desk Lamp/ in Finder and drops a file in it.
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
                   "MODEL-role, so it cannot show the whole-folder-becomes-one-model hazard the " \
                   "ordering comment also names — see the model-role test below for that one.)"
    end

    # THE CATEGORY FOLDER GOES UNDER THE FOLDER THE USER MADE, not a second `Projects/desk-lamp/`
    # tree rebuilt from the slug. See Task 3 — this is that fix, driven through the real door.
    test "the category folder is created under the discovered folder, not a slug-named twin" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_path_exists File.join(@root, "Projects", "Desk Lamp", "design", "panel.svg")
      refute File.exist?(File.join(@root, "Projects", "desk-lamp")),
             "no second Projects/<slug> tree may be minted"
    end

    # THE HAZARD #discover_projects' OWN COMMENT NAMES, DRIVEN FOR REAL. `panel.svg` above cannot
    # exercise it: role "vector" is never MODEL-role, so Maker::ModelIntake.classify never looks at
    # it regardless of which order the two calls run in — the two tests above only pin the
    # PROJECT-INTAKE half of the ordering, not the model-catalog half. This adds a model-role file
    # (.stl) so the nearest-shelf rule in #classify is actually exercised: `Projects/` is a shelf
    # (the seeded `*`), `Desk Lamp` is not, so a file loose there when the catalog looks makes the
    # WHOLE `Desk Lamp` FOLDER the nearest-shelf model, titled after the folder — permanently,
    # because an auto model is only ever created, never reaped.
    #
    # THE HAZARD CHECK RUNS BEFORE THE "FILED CORRECTLY" ASSERTIONS BELOW IT, DELIBERATELY. A
    # failed assertion halts the rest of the test method, and EITHER of #perform's two mutations —
    # discover_projects swapped with intake_project_folders, or discover_projects moved ahead of
    # observer.call — ALSO leaves bracket.stl unfiled, the identical symptom the test above already
    # pins. Asserting "filed correctly" first would hide this hazard's own evidence behind that
    # earlier, already-covered failure. Checked here first and by itself, so a red run reports what
    # actually happened: verified against BOTH mutations (driven directly, not assumed) to name a
    # model titled "Desk Lamp" whose auto_node_id AND folder_node_id both equal the Desk Lamp
    # folder's own node_id — a real folder swallowed, not merely an absent file.
    test "the model catalog never swallows the discovered folder as one model" do
      File.binwrite(File.join(@root, "Projects", "Desk Lamp", "bracket.stl"), "solid")

      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      folder = @user.nodes.present.find_by!(name: "Desk Lamp", kind: "dir")
      swallowed = @user.maker_models.find_by(auto_node_id: folder.node_id) ||
                  @user.maker_models.find_by(folder_node_id: folder.node_id)
      # NAMES THE PRIMARY CAUSE THIS CLASS EXISTS TO CATCH, NOT THE ONLY ONE THAT CAN REACH HERE.
      # Any ordering that leaves bracket.stl loose at the Desk Lamp folder root by the time
      # #intake_models runs reaches this same wrong state — driven and confirmed for both #perform
      # mutations, not merely this one.
      assert_nil swallowed,
                 "the whole Desk Lamp FOLDER became a model — title #{swallowed&.title.inspect}, " \
                 "auto_node_id #{swallowed&.auto_node_id.inspect} — instead of the file getting " \
                 "its own. bracket.stl was still loose at the project root when the model catalog " \
                 "ran (most directly: discover_projects swapped with intake_project_folders in " \
                 "ScanJob#perform, so the intake had no project yet to file it into)."

      assert_path_exists File.join(@root, "Projects", "Desk Lamp", "models", "bracket.stl"),
                          "discovery ran before the intake, so the intake had a project folder to file this into"
      assert_equal [ "bracket" ], @user.maker_models.pluck(:title)
    end
  end
end
