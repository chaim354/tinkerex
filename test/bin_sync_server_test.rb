# frozen_string_literal: true

require "test_helper"
require "open3"
require "fileutils"

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
    # Anchored to each subcommand's DETAIL line, not the one-line summary ("usage: bin/sync-server
    # {prepare|start}") -- that summary already contains the words "prepare" and "start" on its
    # own, so asserting only their bare presence stays green even if BOTH detail lines below it
    # were deleted. Match usage()'s real strings verbatim, spacing included.
    assert_includes out, "prepare  migrate the sync host DB",
                     "the usage message must describe prepare, not just name it"
    assert_includes out, "start    boot the sync host in the foreground",
                     "the usage message must describe start, not just name it"
  end

  # THE THREE TESTS ABOVE ALL SHORT-CIRCUIT AT require_checkout, so a wrong rake task name, a
  # wrong awk field, or a wrong env-file key would be invisible to this suite. This test stubs the
  # two things `prepare` actually shells out to once a checkout exists -- host/bin/rails (a
  # relative path, resolved against the checkout, never PATH) and `bundle` (a bare command,
  # resolved via PATH) -- so it can exercise the awk extraction and the env-file write with NO
  # gems, NO network and NO database. Stubbing `bundle` rather than dropping a real (even empty)
  # Gemfile into the fake checkout is the point: a real Gemfile hands Bundler's own
  # version-dependent behaviour -- which this test does not control and must not depend on -- a
  # chance to touch this box's gem environment or reach for the network.
  test "prepare's happy path writes both keys from what the rake task actually printed" do
    Dir.mktmpdir("sync-stub") do |sync_dir|
      host_bin = File.join(sync_dir, "host", "bin")
      FileUtils.mkdir_p(host_bin)
      rails_stub = File.join(host_bin, "rails")
      File.write(rails_stub, <<~STUB)
        #!/usr/bin/env bash
        # Answers only the two invocations bin/sync-server's prepare case makes -- shaped after
        # the real host/lib/tasks/devices.rake output in chaim354/tinkerex-sync.
        set -euo pipefail
        case "${1:-}" in
          db:prepare)
            exit 0
            ;;
          sync:device:issue)
            echo "user_id:      1"
            echo "device_id:    1"
            echo "device_token: stub-devtoken-9f8e7d6c5b4a"
            echo
            echo "Store it now -- only its digest is kept, so this cannot be shown again."
            ;;
          *)
            echo "stub bin/rails: unhandled task '${1:-}'" >&2
            exit 1
            ;;
        esac
      STUB
      File.chmod(0o755, rails_stub)

      stub_path_dir = File.join(sync_dir, "stub-path")
      FileUtils.mkdir_p(stub_path_dir)
      bundle_stub = File.join(stub_path_dir, "bundle")
      File.write(bundle_stub, <<~STUB)
        #!/usr/bin/env bash
        # No Gemfile exists anywhere under this stub checkout -- prepare must not need one.
        exit 0
      STUB
      File.chmod(0o755, bundle_stub)

      # prepare writes to the REAL repo's tmp/sync-server.env -- there is no override for that
      # path, so a developer's (or another test's) existing file must survive this test having
      # run, regardless of whether one was there to begin with.
      env_file = Rails.root.join("tmp/sync-server.env")
      preexisting = env_file.exist? ? env_file.read : nil

      begin
        out, status = Open3.capture2e(
          { "TINKEREX_SYNC_DIR" => sync_dir, "PATH" => "#{stub_path_dir}:#{ENV.fetch("PATH")}" },
          SCRIPT.to_s, "prepare"
        )

        assert status.success?, "prepare should succeed against a stubbed checkout:\n#{out}"
        written = env_file.read
        assert_includes written, "CHUNK_REMOTE_URL="
        assert_includes written, "CHUNK_REMOTE_TOKEN=stub-devtoken-9f8e7d6c5b4a"
      ensure
        if preexisting
          env_file.write(preexisting)
        else
          FileUtils.rm_f(env_file)
        end
      end
    end
  end
end
