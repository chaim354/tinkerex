require "test_helper"
require "tmpdir"

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

    private

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
