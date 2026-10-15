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
# backend gate.
class BootScanTest < ActiveSupport::TestCase
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

  test "the entry point exists and is gated on the backend, so a non-scannable deployment enqueues nothing" do
    assert_respond_to Library::ScanJob, :scan_all!
    assert_nil Library::ScanJob.scan_all! if !FileLayer.current.capabilities.scannable?
  end
end
