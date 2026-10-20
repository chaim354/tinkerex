require "test_helper"

# THE FIRST SCAN HAPPENS AT BOOT, NOT AT THE NEXT QUARTER HOUR (J, 2026-10-15). config/recurring.yml
# runs Library::ScanJob.scan_all! every 15 minutes on the scheduler's own clock, and nothing else
# enqueued a scan at start-up, so a fresh install's folder sat unindexed for up to 15 minutes while
# the guide said "indexed on start" -- measured on a Mac and on Linux: an empty catalog twenty seconds
# after boot with the folder full. config/puma.rb's on_booted hook closes that. This pin is static,
# because Puma's hooks are not reachable from a Rails test and Capybara boots its own Puma without
# config/puma.rb; the behaviour itself was proved by starting the compose stack and reading the
# catalog with no Rescan (the arc has the numbers). What the pin can catch is the hook being deleted
# or its call drifting away from the schedule's entry point, which is the one that carries the
# backend and library-folder gates.
class BootScanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  PUMA_CONFIG = Rails.root.join("config/puma.rb")

  test "puma enqueues a library scan once booted, through the schedule's own gated entry point" do
    source = PUMA_CONFIG.read
    hook = source[/^on_booted do\n(.*?)^end$/m, 1]
    assert hook, "config/puma.rb has no on_booted block: the first scan is back to the next quarter hour"
    assert_includes hook, "Library::ScanJob.scan_all!",
                    "the hook must call the same entry point config/recurring.yml does (it carries the scannable gate)"
    assert_match(/rescue StandardError/, hook, "an enqueue failure must be logged, never fatal to the boot")
    assert_equal "Library::ScanJob.scan_all!", YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "library_scan", "command"),
                 "the schedule and the boot hook must name one entry point"
  end

  # THE BOOT HOOK WAITS FOR THE FOLDER TOO (K, 2026-10-20): on a fresh share install the hook runs
  # before anyone has said which folder is the library, and scanning the unconfirmed mount is the
  # thing K exists to prevent. Asked of the ambient deployment, so each leg asserts its own answer
  # rather than skipping (§15): share waits until the row exists, s3 has no folder to confirm and
  # schedules either way, chunk_remote is not scanned at all.
  test "the entry point is gated on the backend and on a confirmed library folder" do
    assert_respond_to Library::ScanJob, :scan_all!
    User.create!(email: "boot-#{SecureRandom.hex(4)}@example.com")
    adapter = FileLayer.current
    Setting.forget(Tinkerex::LibraryRoot::KEY)

    if adapter.is_a?(FileLayer::Share)
      assert_no_enqueued_jobs(only: Library::ScanJob) { Library::ScanJob.scan_all! }
      Setting.put(Tinkerex::LibraryRoot::KEY, "")
      assert_enqueued_jobs(1, only: Library::ScanJob) { Library::ScanJob.scan_all! }
    elsif adapter.capabilities.scannable?
      assert_enqueued_jobs(1, only: Library::ScanJob) { Library::ScanJob.scan_all! }
    else
      assert_no_enqueued_jobs(only: Library::ScanJob) { Library::ScanJob.scan_all! }
    end
  end
end
