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

  test "a missing sibling checkout exits non-zero and names the clone command, on either arm" do
    # BOTH ARMS, PINNED rather than inherited: the bare invocation is the Rust arm (D4), which looks
    # for the checkout's Cargo workspace, and SYNC_IMPL=ruby looks for host/ -- each must fail the
    # same loud way. TINKEREX_SYNC_BIN is cleared because a binary named there needs no checkout.
    [ nil, "ruby" ].each do |impl|
      # BLOCK FORM of mktmpdir: the directory only needs to outlive the one child process, and the
      # non-block arm cleans up after nobody -- it left one `absent*` tmpdir behind per run.
      out, status = Dir.mktmpdir("absent") do |absent|
        Open3.capture2e({ "TINKEREX_SYNC_DIR" => absent, "SYNC_IMPL" => impl, "TINKEREX_SYNC_BIN" => nil },
                        SCRIPT.to_s, "prepare")
      end

      arm = impl ? "SYNC_IMPL=#{impl}" : "the bare invocation"
      assert_not status.success?, "#{arm}: a missing tinkerex-sync must fail, not fall through:\n#{out}"
      assert_includes out, "chaim354/tinkerex-sync",
                       "#{arm}: the failure must name the repo, not just the path it looked in"
      assert_includes out, "gh repo clone",
                       "#{arm}: the failure must name the command that fixes it"
    end
  end

  test "an unknown SYNC_IMPL is refused and names the two it knows" do
    out, status = Dir.mktmpdir("impl") do |dir|
      Open3.capture2e({ "TINKEREX_SYNC_DIR" => dir, "SYNC_IMPL" => "python" }, SCRIPT.to_s, "prepare")
    end

    assert_not status.success?
    assert_includes out, "SYNC_IMPL must be ruby or rust"
  end

  # THE RUST ARM (tinkerex-sync's crates/tinkerex-sync), through the same seam as the Ruby arm's
  # happy path below: the binary is stubbed by TINKEREX_SYNC_BIN so no cargo, no build and no
  # database are involved, and the stub answers exactly the two subcommands `prepare` runs
  # (`migrate`, then `device issue`, whose output lines are the rake task's own so the awk is
  # shared). What this pins: the arm reaches the binary with STORAGE_BACKEND=local and its own
  # SQLITE_DATABASE under tmp/ (never host/storage/development.sqlite3), parses the token, and
  # writes the same keys the Ruby arm writes -- the client (config/ci.rb) cannot tell them apart,
  # which is the point.
  test "prepare's Rust arm migrates, issues a device through the stubbed binary and writes the same env file" do
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
      # NO host/ AND NO Cargo.toml in this checkout: with TINKEREX_SYNC_BIN naming a built binary,
      # the Rust arm needs nothing else from it -- and it never needed host/, which Phase 6 deletes.
      env_file = Pathname.new(File.join(sync_dir, "sync-server.env"))

      run_env = {
        "TINKEREX_SYNC_DIR" => sync_dir,
        "TINKEREX_SYNC_BIN" => bin_stub,
        "SYNC_IMPL" => "rust",
        "SYNC_SERVER_ENV_FILE" => env_file.to_s,
        "GITHUB_ACTIONS" => nil # unset even when this suite itself runs in Actions; set below
      }
      out, status = Open3.capture2e(run_env, SCRIPT.to_s, "prepare")

      assert status.success?, "the Rust arm's prepare should succeed against a stubbed binary:\n#{out}"
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

      seen = File.read(File.join(sync_dir, "seen-env"))
      assert_includes seen, "STORAGE_BACKEND=local"
      assert_match(%r{SQLITE_DATABASE=.*/tmp/sync-server-rust\.sqlite3}, seen,
                   "the Rust arm must use its own database under tmp/, never the host's")
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
  #
  # `openssl` (SYNC_ADMIN_TOKEN's generator, Arc C) IS DELIBERATELY NOT STUBBED, UNLIKE `bundle`
  # AND `host/bin/rails`. `openssl rand -hex 32` touches no network, no gem environment and no
  # database -- it is a local, side-effect-free CLI call this box is already known to have (git and
  # curl-https both depend on it), so stubbing it would only add a fake with nothing real to
  # protect against.
  #
  # RESIDUAL, NOT CLOSED: the bundle stub always exits 0, so this cannot tell
  # `bundle install --quiet && bin/rails db:prepare` from a weakened `;`-joined version that
  # would run db:prepare after a failed install.
  test "prepare's happy path writes all four keys, admin token freshly generated" do
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

      # An ISOLATED path, never the real tmp/sync-server.env -- see ENV_FILE's own comment in
      # bin/sync-server for why a save-and-restore of the real file isn't safe here.
      env_file = Pathname.new(File.join(sync_dir, "sync-server.env"))

      # SYNC_IMPL PINNED: this is the RUBY arm's happy path, and the bare invocation is the Rust arm
      # since D4 (2026-10-14), which looks for a Cargo.toml this stub checkout does not have.
      run_env = {
        "TINKEREX_SYNC_DIR" => sync_dir,
        "PATH" => "#{stub_path_dir}:#{ENV.fetch("PATH")}",
        "SYNC_SERVER_ENV_FILE" => env_file.to_s,
        "SYNC_IMPL" => "ruby"
      }

      out, status = Open3.capture2e(run_env, SCRIPT.to_s, "prepare")

      assert status.success?, "prepare should succeed against a stubbed checkout:\n#{out}"
      written = env_file.read
      assert_includes written, "CHUNK_REMOTE_URL="
      assert_includes written, "CHUNK_REMOTE_TOKEN=stub-devtoken-9f8e7d6c5b4a"
      assert_sync_public_url_names_the_local_server(written)

      # SYNC_ADMIN_TOKEN: 64 lowercase hex chars (openssl rand -hex 32), on its own line so the
      # match cannot accidentally span into whatever key follows it in the file.
      admin_line = written[/^SYNC_ADMIN_TOKEN=.*$/]
      assert admin_line, "SYNC_ADMIN_TOKEN was not written:\n#{written}"
      assert_match(/\ASYNC_ADMIN_TOKEN=[0-9a-f]{64}\z/, admin_line,
                   "expected 64 lowercase hex chars from `openssl rand -hex 32`, got: #{admin_line.inspect}")

      # FRESH EVERY prepare, NOT A FIXED STUB VALUE LIKE THE DEVICE TOKEN ABOVE -- unlike
      # sync:device:issue, nothing on the sync host mints this value, so `prepare` has to generate
      # it itself, and a second run must not silently reuse the first's.
      second_out, second_status = Open3.capture2e(run_env, SCRIPT.to_s, "prepare")
      assert second_status.success?, "a second prepare should also succeed:\n#{second_out}"
      second_admin_line = env_file.read[/^SYNC_ADMIN_TOKEN=.*$/]
      assert_not_equal admin_line, second_admin_line,
                        "two prepare runs wrote the SAME admin token -- it must be freshly " \
                        "generated per run, not a fixed or cached value"
    end
  end

  # THE CUTOVER'S D4 (2026-10-14): THE BARE INVOCATION IS THE RUST ARM -- the server production has
  # run since the 2026-10-07 cutover, so the chunk_remote gate grades the one devices meet -- and
  # SYNC_IMPL=ruby still boots the Ruby host until the rewrite plan's §9 (Phase 6) deletes it. ONE
  # checkout holds a stub of each, minting DIFFERENT tokens, so the env file names the arm that ran.
  test "a bare invocation runs the Rust binary, and SYNC_IMPL=ruby still the Ruby host" do
    Dir.mktmpdir("sync-default") do |sync_dir|
      binary = File.join(sync_dir, "tinkerex-sync")
      write_binary_stub(binary, token: "stub-rust-default-0a1b2c")
      path_dir = write_ruby_host_stub(sync_dir, token: "stub-ruby-host-3d4e5f")
      env_file = File.join(sync_dir, "sync-server.env")
      base_env = { "TINKEREX_SYNC_DIR" => sync_dir, "TINKEREX_SYNC_BIN" => binary,
                   "SYNC_SERVER_ENV_FILE" => env_file, "PATH" => "#{path_dir}:#{ENV.fetch("PATH")}",
                   "GITHUB_ACTIONS" => nil }

      { nil => "stub-rust-default-0a1b2c", "ruby" => "stub-ruby-host-3d4e5f" }.each do |impl, token|
        arm = impl ? "SYNC_IMPL=#{impl}" : "the bare invocation"
        FileUtils.rm_f(env_file)
        out, status = Open3.capture2e(base_env.merge("SYNC_IMPL" => impl), SCRIPT.to_s, "prepare")

        assert status.success?, "#{arm}: prepare failed:\n#{out}"
        assert_equal token, File.read(env_file)[/^CHUNK_REMOTE_TOKEN=(.*)$/, 1], "#{arm} ran the wrong arm"
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
  test "the Rust arm runs the binary from wherever CARGO_TARGET_DIR made cargo put it" do
    # unset: the checkout's own target/. Absolute: ci.yml's shape. Relative: resolved against the
    # checkout, where cargo runs -- not against wherever bin/sync-server was invoked from.
    [ nil, :absolute, "relative-target" ].each do |shape|
      Dir.mktmpdir("sync-cargo") do |sync_dir|
        target_dir = shape == :absolute ? File.join(sync_dir, "kept", "cargo-target") : shape
        File.write(File.join(sync_dir, "Cargo.toml"), "") # what the Rust arm checks a checkout for
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

        run_env = { "TINKEREX_SYNC_DIR" => sync_dir, "TINKEREX_SYNC_BIN" => nil, "SYNC_IMPL" => "rust",
                    "CARGO_TARGET_DIR" => target_dir, "SYNC_SERVER_ENV_FILE" => env_file,
                    "PATH" => "#{path_dir}:#{ENV.fetch("PATH")}", "GITHUB_ACTIONS" => nil }
        out, status = Open3.capture2e(run_env, SCRIPT.to_s, "prepare")

        assert status.success?, "CARGO_TARGET_DIR=#{target_dir.inspect}: prepare did not run what cargo built:\n#{out}"
        assert_includes File.read(env_file), "CHUNK_REMOTE_TOKEN=stub-cargo-built-6a7b8c"
      end
    end
  end

  # A stand-in for the tinkerex-sync binary: the two subcommands `prepare` runs, answered the way
  # crates/tinkerex-sync/src/main.rs answers them, with the device token given.
  def write_binary_stub(path, token:)
    File.write(path, <<~STUB)
      #!/usr/bin/env bash
      set -euo pipefail
      case "${1:-} ${2:-}" in
        "migrate ") echo "Created" ;;
        "device issue") echo "device_token: #{token}" ;;
        *) echo "stub tinkerex-sync: unhandled '$*'" >&2; exit 1 ;;
      esac
    STUB
    File.chmod(0o755, path)
  end

  # A stand-in for the Ruby host: host/bin/rails answering the two tasks `prepare` runs, and a
  # do-nothing `bundle` in a directory the caller puts on PATH, which is returned.
  def write_ruby_host_stub(sync_dir, token:)
    rails = File.join(sync_dir, "host", "bin", "rails")
    FileUtils.mkdir_p(File.dirname(rails))
    File.write(rails, <<~STUB)
      #!/usr/bin/env bash
      set -euo pipefail
      case "${1:-}" in
        db:prepare) ;;
        sync:device:issue) echo "device_token: #{token}" ;;
        *) echo "stub bin/rails: unhandled task '${1:-}'" >&2; exit 1 ;;
      esac
    STUB
    File.chmod(0o755, rails)
    path_dir = File.join(sync_dir, "stub-path")
    FileUtils.mkdir_p(path_dir)
    File.write(File.join(path_dir, "bundle"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod(0o755, File.join(path_dir, "bundle"))
    path_dir
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
