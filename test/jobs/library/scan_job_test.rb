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

        with_env("LIBRARY_BACKEND" => "chunk") do
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
      with_env("LIBRARY_BACKEND" => "chunk") do
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
    test "a rootless scan in chunk mode raises rather than silently doing nothing" do
      user = user!
      with_env("LIBRARY_BACKEND" => "chunk") do
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
end
