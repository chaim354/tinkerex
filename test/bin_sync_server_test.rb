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
    # The script looks for the checkout's Cargo workspace. TINKEREX_SYNC_BIN is cleared because a
    # binary named there needs no checkout, and SYNC_IMPL because a stray one is refused first.
    # BLOCK FORM of mktmpdir: the directory only needs to outlive the one child process, and the
    # non-block arm cleans up after nobody -- it left one `absent*` tmpdir behind per run.
    out, status = Dir.mktmpdir("absent") do |absent|
      Open3.capture2e({ "TINKEREX_SYNC_DIR" => absent, "SYNC_IMPL" => nil, "TINKEREX_SYNC_BIN" => nil },
                      SCRIPT.to_s, "prepare")
    end

    assert_not status.success?, "a missing tinkerex-sync must fail, not fall through:\n#{out}"
    assert_includes out, "chaim354/tinkerex-sync",
                     "the failure must name the repo, not just the path it looked in"
    assert_includes out, "gh repo clone", "the failure must name the command that fixes it"
  end

  # PHASE 6 (2026-10-14) DELETED THE RUBY HOST, AND SYNC_IMPL CHOOSES NOTHING ANY MORE -- so any
  # value but `rust` is REFUSED, not ignored. `ruby` is the one anyone would type (the two-arm era's
  # spelling for the host), and ignoring it would grade the Rust server while the caller believed
  # they were testing the Ruby one; `python` stands for anything else. Refused BEFORE ANYTHING RUNS,
  # on both subcommands: the stub binary records every call it gets, and a refusal after it ran is
  # too late.
  test "any SYNC_IMPL but rust is refused before the binary runs, on both subcommands" do
    Dir.mktmpdir("sync-impl") do |sync_dir|
      binary = File.join(sync_dir, "tinkerex-sync")
      write_binary_stub(binary, token: "stub-refused-0f1e2d")
      env_file = File.join(sync_dir, "sync-server.env")

      %w[ruby python].product(%w[prepare start]).each do |impl, subcommand|
        run_env = { "TINKEREX_SYNC_DIR" => sync_dir, "TINKEREX_SYNC_BIN" => binary,
                    "SYNC_SERVER_ENV_FILE" => env_file, "SYNC_IMPL" => impl, "GITHUB_ACTIONS" => nil }
        out, status = Open3.capture2e(run_env, SCRIPT.to_s, subcommand)

        arm = "SYNC_IMPL=#{impl} bin/sync-server #{subcommand}"
        assert_equal 64, status.exitstatus, "#{arm} must be refused, not run:\n#{out}"
        assert_includes out, "SYNC_IMPL='#{impl}': bin/sync-server boots only the Rust binary", arm
        assert_not File.exist?(File.join(sync_dir, "calls")), "#{arm} reached the binary before refusing"
        assert_not File.exist?(env_file), "#{arm} wrote an env file before refusing"
      end
    end
  end

  # THE HAPPY PATH, with the binary stubbed by TINKEREX_SYNC_BIN so no cargo, no build and no
  # database are involved: the stub answers exactly the two subcommands `prepare` runs (`migrate`,
  # then `device issue`, in the shape crates/tinkerex-sync/src/main.rs prints them). What this pins:
  # the script reaches the binary with STORAGE_BACKEND=local, its own SQLITE_DATABASE under this
  # repo's tmp/ and a SECRET_KEY_BASE, parses the token, and writes the four keys config/ci.rb sources.
  #
  # `openssl` (SYNC_ADMIN_TOKEN's generator, Arc C) IS DELIBERATELY NOT STUBBED: `openssl rand -hex
  # 32` touches no network, no gem environment and no database, so a fake would have nothing real to
  # protect against.
  test "prepare migrates, issues a device through the stubbed binary and writes the env file" do
    Dir.mktmpdir("sync-rust-stub") do |sync_dir|
      bin_stub = File.join(sync_dir, "tinkerex-sync")
      File.write(bin_stub, <<~STUB)
        #!/usr/bin/env bash
        # Shaped after the real binary's `migrate` and `device issue` output (tinkerex-sync
        # crates/tinkerex-sync/src/main.rs). Records the env it was reached with, for assertions.
        set -euo pipefail
        printf '%s\n' "STORAGE_BACKEND=${STORAGE_BACKEND:-unset}" "SQLITE_DATABASE=${SQLITE_DATABASE:-unset}" \
          "SECRET_KEY_BASE=${SECRET_KEY_BASE:-unset}" >> "#{sync_dir}/seen-env"
        case "${1:-} ${2:-}" in
          "migrate ")
            echo "Created"
            ;;
          "device issue")
            echo "user_id:      1"
            echo "device_id:    1"
            echo "device_token: stub-rust-devtoken-1a2b3c4d5e6f"
            echo
            echo "Store it now -- only its digest is kept, so this cannot be shown again."
            ;;
          *)
            echo "stub tinkerex-sync: unhandled '$*'" >&2
            exit 1
            ;;
        esac
      STUB
      File.chmod(0o755, bin_stub)
      # NO Cargo.toml in this checkout: with TINKEREX_SYNC_BIN naming a built binary, the script
      # needs nothing else from it.
      env_file = Pathname.new(File.join(sync_dir, "sync-server.env"))

      run_env = {
        "TINKEREX_SYNC_DIR" => sync_dir,
        "TINKEREX_SYNC_BIN" => bin_stub,
        "SYNC_IMPL" => nil,
        "SYNC_SERVER_ENV_FILE" => env_file.to_s,
        "GITHUB_ACTIONS" => nil # unset even when this suite itself runs in Actions; set below
      }
      out, status = Open3.capture2e(run_env, SCRIPT.to_s, "prepare")

      assert status.success?, "prepare should succeed against a stubbed binary:\n#{out}"
      written = env_file.read
      assert_includes written, "CHUNK_REMOTE_URL="
      assert_includes written, "CHUNK_REMOTE_TOKEN=stub-rust-devtoken-1a2b3c4d5e6f"
      assert_match(/^SYNC_ADMIN_TOKEN=[0-9a-f]{64}$/, written)
      assert_sync_public_url_names_the_local_server(written)
      admin_token = written[/^SYNC_ADMIN_TOKEN=(\h{64})$/, 1]

      # THE FILE IS THE INTERFACE; STDOUT IS A LOG, and CI logs are public once the repo is. The
      # tokens go in the file above and must not be echoed beside it.
      assert_not_includes out, "stub-rust-devtoken-1a2b3c4d5e6f", "prepare echoed the device token"
      assert_not_includes out, admin_token, "prepare echoed the admin token"
      assert_includes out, "CHUNK_REMOTE_TOKEN=[redacted]"

      # Under Actions each value is ALSO registered as a mask, so a later accidental echo is starred.
      out, status = Open3.capture2e(run_env.merge("GITHUB_ACTIONS" => "true"), SCRIPT.to_s, "prepare")
      assert status.success?, out
      fresh_admin = env_file.read[/^SYNC_ADMIN_TOKEN=(\h{64})$/, 1]
      assert_includes out, "::add-mask::stub-rust-devtoken-1a2b3c4d5e6f"
      assert_includes out, "::add-mask::#{fresh_admin}"
      # FRESH EVERY prepare, NOT A FIXED VALUE LIKE THE STUB'S DEVICE TOKEN: nothing on the server
      # mints this one, so `prepare` generates it, and a second run must not reuse the first's.
      assert_not_equal admin_token, fresh_admin, "two prepare runs wrote the SAME admin token"

      seen = File.read(File.join(sync_dir, "seen-env"))
      assert_includes seen, "STORAGE_BACKEND=local"
      assert_match(%r{SQLITE_DATABASE=.*/tmp/sync-server-rust\.sqlite3}, seen,
                   "the server must use its own database under this repo's tmp/")
      assert_not_includes seen, "SECRET_KEY_BASE=unset", "the binary refuses to boot without one"
    end
  end

  test "an unknown subcommand is refused rather than silently doing nothing" do
    out, status = Open3.capture2e(SCRIPT.to_s, "frobnicate")

    assert_not status.success?
    # Anchored to each subcommand's DETAIL line, not the one-line summary ("usage: bin/sync-server
    # {prepare|start}") -- that summary already contains the words "prepare" and "start" on its
    # own, so asserting only their bare presence stays green even if BOTH detail lines below it
    # were deleted. Match usage()'s real strings verbatim, spacing included.
    assert_includes out, "prepare  build tinkerex-sync, migrate its DB",
                     "the usage message must describe prepare, not just name it"
    assert_includes out, "start    boot the sync server in the foreground",
                     "the usage message must describe start, not just name it"
  end

  # THE CUTOVER-ERA SPELLING STILL MEANS THE BINARY. From the cutover (2026-10-07) until Phase 6 the
  # documented command was `SYNC_IMPL=rust bin/sync-server`, and the plans and the client repo's notes
  # still spell it that way; refusing a caller for asking for exactly what it gets would protect
  # nothing. tinkerex-sync's bin/build-and-push accepts it for the same reason.
  test "a bare invocation and SYNC_IMPL=rust both run the binary" do
    Dir.mktmpdir("sync-default") do |sync_dir|
      binary = File.join(sync_dir, "tinkerex-sync")
      write_binary_stub(binary, token: "stub-rust-default-0a1b2c")
      env_file = File.join(sync_dir, "sync-server.env")
      base_env = { "TINKEREX_SYNC_DIR" => sync_dir, "TINKEREX_SYNC_BIN" => binary,
                   "SYNC_SERVER_ENV_FILE" => env_file, "GITHUB_ACTIONS" => nil }

      [ nil, "rust" ].each do |impl|
        arm = impl ? "SYNC_IMPL=#{impl}" : "the bare invocation"
        FileUtils.rm_f(env_file)
        out, status = Open3.capture2e(base_env.merge("SYNC_IMPL" => impl), SCRIPT.to_s, "prepare")

        assert status.success?, "#{arm}: prepare failed:\n#{out}"
        assert_equal "stub-rust-default-0a1b2c", File.read(env_file)[/^CHUNK_REMOTE_TOKEN=(.*)$/, 1],
                     "#{arm} did not run the binary"
      end
    end
  end

  # WHERE CARGO PUTS THE BINARY IS WHERE THE SCRIPT MUST RUN IT FROM. ci.yml's test-chunk-remote job
  # sets CARGO_TARGET_DIR -- a directory the runner keeps, outside the checkout actions/checkout
  # cleans -- and cargo then builds into $CARGO_TARGET_DIR/release, relative to the directory it
  # runs in (the checkout), never into the checkout's target/. A script that ran
  # target/release/tinkerex-sync regardless built the binary in one place and looked in another.
  # `cargo` is stubbed on PATH and compiles nothing: it drops a stub binary where cargo's documented
  # rule puts it (a relative CARGO_TARGET_DIR is relative to cargo's working directory). The real
  # cargo was driven by hand, unset and absolute.
  #
  # ONE CHECKOUT PER CASE, deliberately: a binary left behind by an earlier case is found by a
  # script that looks in the wrong place, and the mutation check then stays green.
  test "the script runs the binary from wherever CARGO_TARGET_DIR made cargo put it" do
    # unset: the checkout's own target/. Absolute: ci.yml's shape. Relative: resolved against the
    # checkout, where cargo runs -- not against wherever bin/sync-server was invoked from.
    [ nil, :absolute, "relative-target" ].each do |shape|
      Dir.mktmpdir("sync-cargo") do |sync_dir|
        target_dir = shape == :absolute ? File.join(sync_dir, "kept", "cargo-target") : shape
        File.write(File.join(sync_dir, "Cargo.toml"), "") # what the script checks a checkout for
        built = File.join(sync_dir, "what-cargo-builds")
        write_binary_stub(built, token: "stub-cargo-built-6a7b8c")
        path_dir = File.join(sync_dir, "stub-path")
        FileUtils.mkdir_p(path_dir)
        File.write(File.join(path_dir, "cargo"), <<~STUB)
          #!/usr/bin/env bash
          # Answers only the build bin/sync-server runs, laying the artifact out the way cargo does.
          set -euo pipefail
          [ "$*" = "build --release --quiet -p tinkerex-sync" ] || { echo "stub cargo: unhandled '$*'" >&2; exit 1; }
          out="${CARGO_TARGET_DIR:-target}/release"
          mkdir -p "$out"
          cp "#{built}" "$out/tinkerex-sync"
          chmod +x "$out/tinkerex-sync"
        STUB
        File.chmod(0o755, File.join(path_dir, "cargo"))
        env_file = File.join(sync_dir, "sync-server.env")

        run_env = { "TINKEREX_SYNC_DIR" => sync_dir, "TINKEREX_SYNC_BIN" => nil, "SYNC_IMPL" => nil,
                    "CARGO_TARGET_DIR" => target_dir, "SYNC_SERVER_ENV_FILE" => env_file,
                    "PATH" => "#{path_dir}:#{ENV.fetch("PATH")}", "GITHUB_ACTIONS" => nil }
        out, status = Open3.capture2e(run_env, SCRIPT.to_s, "prepare")

        assert status.success?, "CARGO_TARGET_DIR=#{target_dir.inspect}: prepare did not run what cargo built:\n#{out}"
        assert_includes File.read(env_file), "CHUNK_REMOTE_TOKEN=stub-cargo-built-6a7b8c"
      end
    end
  end

  # A stand-in for the tinkerex-sync binary: the two subcommands `prepare` runs, answered the way
  # crates/tinkerex-sync/src/main.rs answers them, with the device token given. Every call is
  # appended to a `calls` file beside the stub, so a test can tell "never ran" from "ran and failed".
  def write_binary_stub(path, token:)
    File.write(path, <<~STUB)
      #!/usr/bin/env bash
      set -euo pipefail
      echo "$*" >> "$(dirname "$0")/calls"
      case "${1:-} ${2:-}" in
        "migrate ") echo "Created" ;;
        "device issue") echo "device_token: #{token}" ;;
        *) echo "stub tinkerex-sync: unhandled '$*'" >&2; exit 1 ;;
      esac
    STUB
    File.chmod(0o755, path)
  end

  # SYNC_PUBLIC_URL (D1, 2026-10-13): the address a device that signs in to the maker app is handed
  # as its sync server, and LibraryBackendCheck refuses chunk_remote without it -- so if `prepare`
  # stopped writing it, the chunk_remote gate's first FileLayer.build would refuse before a single
  # test ran. The leg is ONE box, so it is the very server CHUNK_REMOTE_URL names.
  def assert_sync_public_url_names_the_local_server(written)
    public_url = written[/^SYNC_PUBLIC_URL=(.*)$/, 1]
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+\z}, public_url.to_s, "SYNC_PUBLIC_URL was not written:\n#{written}")
    assert_equal written[/^CHUNK_REMOTE_URL=(.*)$/, 1], public_url,
                 "one box: the devices' address and the app's are the same local server"
  end
end
