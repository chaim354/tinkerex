# frozen_string_literal: true

require "test_helper"
require "open3"

# GUARDS THE ONE THING THAT CAN BE GUARDED WITHOUT A CHECKOUT: that a missing sibling repo fails
# LOUDLY and names the fix. This is the shape scripts/r2-cutover/smoke.sh already uses for
# tinkerex-client, and the reason is the same -- nothing in bin/ci boots a sync server, so the
# script's failure message IS its error handling (CLAUDE.md §14i: some things cannot go red in CI,
# so the message has to carry the whole story).
class BinSyncServerTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/sync-server")

  test "the script is executable" do
    assert SCRIPT.exist?, "bin/sync-server is missing"
    assert SCRIPT.executable?, "bin/sync-server must be chmod +x or CI cannot invoke it"
  end

  test "a missing sibling checkout exits non-zero and names the clone command" do
    out, status = Open3.capture2e(
      { "TINKEREX_SYNC_DIR" => Dir.mktmpdir("absent") }, SCRIPT.to_s, "prepare"
    )

    assert_not status.success?, "a missing tinkerex-sync must fail, not fall through:\n#{out}"
    assert_includes out, "chaim354/tinkerex-sync",
                     "the failure must name the repo, not just the path it looked in"
    assert_includes out, "gh repo clone",
                     "the failure must name the command that fixes it"
  end

  test "an unknown subcommand is refused rather than silently doing nothing" do
    out, status = Open3.capture2e(SCRIPT.to_s, "frobnicate")

    assert_not status.success?
    assert_includes out, "prepare", "the usage message must name the real subcommands"
    assert_includes out, "start"
  end
end
