require "test_helper"
require "open3"
require "socket"
require "tmpdir"

# ops/share-mount-recover.sh STOPS A CONTAINER THAT SERVES REAL DATA, so its guards are driven here
# against a fake toolchain before they are ever trusted on the box. The fakes (`docker`, `mount`,
# `timeout`, `logger`) sit first on a PATH the script may append to but not replace; they answer
# from a state directory this test writes per scenario and log every call, so each test asserts
# what was stopped and removed — and, far more often, that NOTHING was. The shapes the fake docker
# answers with were captured from the live box on 2026-11-04 (`docker ps --format '{{.ID}} {{.Names}}'`,
# the Mounts JSON, `mount`'s cifs line); ls's stale wording is coreutils' for ESTALE. §14e: a fake that
# shares the code's misunderstanding confirms it, so the answers are copied, not invented.
#
# Pings go to a socket this test owns. The read-only mode (`--check`) must never connect to it; the
# monitor must, with exactly one `status=` in the request (ops/backup-db.sh's query-string rule), and
# the ping.env value must be read literally, never executed.
#
# The constants the script spells (container filter, volume, LIBRARY_PATH) are held to the merged
# Kamal config for the share destination, the way test/ops_backup_table_test.rb holds the backup
# table — a renamed volume would otherwise make every check pass over the wrong mount.
class OpsShareMountTest < ActiveSupport::TestCase
  ROOT = Rails.root
  SCRIPT = ROOT.join("ops/share-mount-recover.sh")
  INSTALLER = ROOT.join("bin/share-mount-monitor-install")
  VOLUME = "tinkerex_library_3dprinting"
  MOUNTPOINT = "/var/lib/docker/volumes/#{VOLUME}/_data"
  SAMPLE_VERSIONS = %w[0d8f6b4a2c9e7f5d3b1a0c8e6f4d2b9a7c5e3f1d e6a4c2f0d8b6a9c7e5f3d1b0a8c6e4f2d0b9a7c5].freeze
  OLD = [ "fb824a55db58", "tinkerex-web-share-b7fb545560da98f70a059386e2c409336d5ef5c5" ].freeze
  NEW = [ "0a1b2c3d4e5f", "tinkerex-web-share-47064f2a9c0e1b2d3f4a5b6c7d8e9f0a1b2c3d4e" ].freeze

  setup do
    @home = Dir.mktmpdir("ops-share-mount")
    @state = File.join(@home, "state")
    @bin = File.join(@home, "fakebin")
    @ops = File.join(@home, "tinkerex-ops")
    [ @state, @bin, @ops ].each { |dir| FileUtils.mkdir_p(dir) }
    @kuma = TCPServer.new("127.0.0.1", 0)
    @smb = TCPServer.new("127.0.0.1", 0)
    write_fakes
  end

  teardown do
    @kuma.close
    @smb.close
    @responder&.join(2)
    FileUtils.remove_entry(@home)
  end

  # ---- the healthy path: the no-op the deploy pre-flight runs every time ------------------------

  test "a healthy mount is a no-op in every mode: exit 0, nothing stopped, nothing removed" do
    running(OLD); ls(OLD, :ok); mounted!

    out, _err, status = run_script("--check")
    assert_equal 0, status.exitstatus
    assert_match(/healthy/, out)

    out, _err, status = run_script
    assert_equal 0, status.exitstatus, out
    assert_match(/Nothing to do/, out)
    assert_no_calls(/\A(stop|rm) /)
    assert mounted?, "a healthy run must not have released the mount"
  end

  # ---- the stale path: the five deploys this exists for ---------------------------------------

  test "a stale handle with Tower answering is recovered: stop the old, rm the Created, confirm the mount is gone" do
    running(OLD); ls(OLD, :stale); created(NEW); mounted!; stop_releases!

    out, err, status = run_script(smb_port: smb_port)
    assert_equal 0, status.exitstatus, "#{out}\n#{err}"
    assert_equal [ "stop #{OLD[0]}", "rm #{NEW[0]}" ], calls.grep(/\A(stop|rm) /),
                 "the old container is stopped first, then the half-created one removed, and nothing else"
    refute mounted?, "the dead mount must be gone afterwards"
    assert_match(/mounts of .* before: 1/, out)
    assert_match(/after: 0/, out)
    assert_match(/kamal deploy -d share --skip-push/, out, "the next step is spelled out")

    # IDEMPOTENT: a second run finds nothing running and nothing mounted, and does nothing.
    out, _err, status = run_script(smb_port: smb_port)
    assert_equal 0, status.exitstatus, out
    assert_match(/already recovered/, out)
    assert_equal 2, calls.grep(/\A(stop|rm) /).size, "the re-run stopped or removed something"
  end

  test "Tower unreachable refuses with 20 and stops nothing — there is nothing to remount yet" do
    running(OLD); ls(OLD, :stale); created(NEW); mounted!; stop_releases!

    out, err, status = run_script(smb_port: closed_port)
    assert_equal 20, status.exitstatus, "#{out}\n#{err}"
    assert_match(/does not answer on/, err)
    assert_match(/NOT stopped/, err)
    assert_no_calls(/\A(stop|rm) /)
    assert mounted?
  end

  test "a mount still held after the stop is reported as incomplete (23), with where to look" do
    running(OLD); ls(OLD, :stale); mounted!   # no stop_releases!: something else holds the mount

    out, err, status = run_script(smb_port: smb_port)
    assert_equal 23, status.exitstatus, "#{out}\n#{err}"
    assert_equal [ "stop #{OLD[0]}" ], calls.grep(/\A(stop|rm) /)
    assert_match(/still held/, err)
    assert_match(/docker ps -a --filter volume=#{VOLUME}/, err)
  end

  # ---- the guards against a failure that is NOT a stale handle ----------------------------------

  test "an ls failure that is not a stale handle refuses with 21 and stops nothing" do
    running(OLD); ls(OLD, :denied); mounted!

    out, err, status = run_script(smb_port: smb_port)
    assert_equal 21, status.exitstatus, "#{out}\n#{err}"
    assert_match(/Permission denied/, err)
    assert_no_calls(/\A(stop|rm) /)

    _out, _err, status = run_script("--check")
    assert_equal 21, status.exitstatus
  end

  test "an ls that hangs (timeout's 124) is 'hung', not stale: refused with 21, nothing stopped" do
    running(OLD); ls(OLD, :hang); mounted!

    out, err, status = run_script(smb_port: smb_port)
    assert_equal 21, status.exitstatus, "#{out}\n#{err}"
    assert_match(/did not answer/, err)
    assert_no_calls(/\A(stop|rm) /)
  end

  test "two running share containers mean a deploy is in progress: refused with 22, even when one is stale" do
    running(OLD, NEW); ls(OLD, :ok); ls(NEW, :ok); mounted!
    out, _err, status = run_script("--check")
    assert_equal 0, status.exitstatus, out
    _out, err, status = run_script(smb_port: smb_port)
    assert_equal 22, status.exitstatus, err
    assert_match(/deploy is in progress/, err)
    assert_no_calls(/\A(stop|rm) /)

    ls(OLD, :stale)
    out, _err, status = run_script("--check")
    assert_equal 10, status.exitstatus, "--check reports the stale one during the overlap: #{out}"
    _out, err, status = run_script(smb_port: smb_port)
    assert_equal 22, status.exitstatus, err
    assert_no_calls(/\A(stop|rm) /)
  end

  test "no running share container: --check says so (22); recover removes a Created leftover and refuses a held mount" do
    created(NEW); mounted!
    _out, _err, status = run_script("--check")
    assert_equal 22, status.exitstatus

    out, err, status = run_script(smb_port: smb_port)
    assert_equal 23, status.exitstatus, "#{out}\n#{err}"
    assert_equal [ "rm #{NEW[0]}" ], calls.grep(/\A(stop|rm) /), "nothing to stop, but the Created one goes"
  end

  test "an unknown flag is a usage error" do
    _out, err, status = run_script("--bogus")
    assert_equal 64, status.exitstatus
    assert_match(/usage/, err)
    assert_empty calls
  end

  # ---- the monitor: loud, pushed, never recovering -------------------------------------------

  test "--check never pings, whatever it finds" do
    running(OLD); ls(OLD, :stale); mounted!
    ping_env("PING_SHARE_MOUNT=#{kuma_url}")
    _out, _err, status = run_script("--check")
    assert_equal 10, status.exitstatus
    assert_never_pinged
  end

  test "--monitor on a stale mount logs loudly, pushes down with the diagnosis, and stops nothing" do
    running(OLD); ls(OLD, :stale); mounted!
    ping_env("PING_SHARE_MOUNT=#{kuma_url}")
    respond_to_pings

    out, _err, status = run_script("--monitor")
    assert_equal 10, status.exitstatus, out
    assert_match(/!! share library stale/, out)
    assert_match(/Stale file handle/, out)
    assert_match(/share-mount-recover\.sh/, out, "the log line names the recovery")
    assert_no_calls(/\A(stop|rm) /)
    assert_match(/-p daemon\.err .*stale/, logged.join("\n"), "syslog gets the error line")
    assert_equal "stale", File.read(File.join(@ops, "share-mount.state")).strip

    request = pinged.first
    assert request, "the monitor did not ping"
    assert_equal 1, request.scan(/[?&]status=/).size, "exactly one status= (the UI's query string must be stripped): #{request}"
    assert_match(/status=down/, request)
    assert_match(/msg=share\+library\+stale/, request)
  end

  test "--monitor is quiet when healthy, pings up, and writes one line when the state comes back" do
    running(OLD); ls(OLD, :ok); mounted!
    ping_env("PING_SHARE_MOUNT=#{kuma_url}")
    File.write(File.join(@ops, "share-mount.state"), "stale\n")
    respond_to_pings

    out, _err, status = run_script("--monitor")
    assert_equal 0, status.exitstatus, out
    assert_match(/healthy again/, out)
    assert_match(/status=up/, pinged.first.to_s)
    assert_equal "healthy", File.read(File.join(@ops, "share-mount.state")).strip

    out, _err, status = run_script("--monitor")
    assert_equal 0, status.exitstatus
    assert_empty out, "a healthy run after a healthy run writes nothing to the log"
    assert_no_calls(/\A(stop|rm) /)
  end

  test "--monitor with no share container running pushes down too" do
    ping_env("PING_SHARE_MOUNT=#{kuma_url}")
    respond_to_pings
    out, _err, status = run_script("--monitor")
    assert_equal 22, status.exitstatus
    assert_match(/no share container is running/, out)
    assert_match(/status=down/, pinged.first.to_s)
  end

  test "ping.env is parsed, never sourced, and only the PING_SHARE_MOUNT line is read" do
    running(OLD); ls(OLD, :ok); mounted!
    sentinel = File.join(@home, "sourced")
    ping_env("PING_SHARE=#{kuma_url}", "PING_SHARE_MOUNT=$(touch #{sentinel})`touch #{sentinel}`")
    _out, _err, status = run_script("--monitor")
    assert_equal 0, status.exitstatus
    assert_not File.exist?(sentinel), "ping.env was EXECUTED. It must be parsed, never sourced."
    assert_never_pinged "a value that is not a URL cannot reach the backup's PING_SHARE line instead"
  end

  # ---- the constants, held to what they describe -------------------------------------------------

  test "the container filter, volume and library path are the share destination's" do
    source = SCRIPT.read
    filter = source[/^CONTAINER_FILTER='([^']+)'/, 1]
    volume = source[/^LIBRARY_VOLUME="\$\{LIBRARY_VOLUME:-([^}]+)\}"/, 1]
    path = source[/^LIBRARY_PATH="\$\{LIBRARY_PATH:-([^}]+)\}"/, 1]
    assert filter && volume && path, "could not read the three constants off ops/share-mount-recover.sh; did their spelling change?"

    share = kamal_config("share")
    SAMPLE_VERSIONS.each do |version|
      assert_match Regexp.new(filter), share.primary_role.container_name(version), "the filter must find the share container"
      assert_no_match Regexp.new(filter), kamal_config(nil).primary_role.container_name(version), "the filter must not match the base container"
      assert_no_match Regexp.new(filter), kamal_config("s3").primary_role.container_name(version), "the filter must not match the s3 container"
    end

    mounts = Array(share.raw_config["volumes"]).map { |spec| spec.split(":") }
    library = mounts.find { |_, dest| dest == path }
    assert library, "config/deploy.share.yml mounts nothing at #{path}; LIBRARY_PATH moved?"
    assert_equal library.first, volume, "the script's default volume is not the one deploy.share.yml mounts at #{path}"
    assert_equal path, share.raw_config.dig("env", "clear", "LIBRARY_PATH"), "deploy.share.yml's LIBRARY_PATH is not what the script checks"
  end

  test "the installer reaches the same box as the backup scripts" do
    mine = INSTALLER.read[/DEPLOY_HOST:-([^}]+)\}/, 1]
    theirs = ROOT.join("bin/backup-cron-install").read[/DEPLOY_HOST:-([^}]+)\}/, 1]
    assert mine && theirs, "no DEPLOY_HOST default found"
    assert_equal theirs, mine
  end

  test "the deploy skill runs the check before the build, and DEPLOY.md names the recovery" do
    skill = ROOT.join(".claude/commands/deploy.md").read
    build = skill.index("## 2. Build once")
    check = skill.index("ls /library")
    recovery = skill.index("ops/share-mount-recover.sh")
    assert build && check && recovery, "the deploy skill lost its build heading, the ls /library check or the recovery script"
    assert_operator check, :<, build, "the stale-mount check must sit in the pre-flight, before `kamal build push`"
    assert_operator recovery, :<, build

    deploy_doc = ROOT.join("docs/DEPLOY.md").read
    assert_includes deploy_doc, "ops/share-mount-recover.sh"
    assert_includes deploy_doc, "bin/share-mount-monitor-install"
  end

  private

  # ---- scenario state the fakes read --------------------------------------------------------------

  def running(*containers)
    File.write(File.join(@state, "running"), containers.map { |id, name| "#{id} #{name}\n" }.join)
  end

  def created(*containers)
    File.write(File.join(@state, "created"), containers.map { |id, name| "#{id} #{name}\n" }.join)
  end

  def ls(container, result)
    File.write(File.join(@state, "ls.#{container[0]}"), result.to_s)
  end

  def mounted! = FileUtils.touch(File.join(@state, "mounted"))
  def mounted? = File.exist?(File.join(@state, "mounted"))
  def stop_releases! = FileUtils.touch(File.join(@state, "stop_releases"))

  def ping_env(*lines)
    File.write(File.join(@ops, "ping.env"), lines.map { |line| "#{line}\n" }.join)
  end

  def calls
    path = File.join(@state, "calls.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def logged
    path = File.join(@state, "logger.log")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def assert_no_calls(pattern)
    assert_empty calls.grep(pattern), "the fake docker saw: #{calls.grep(pattern).inspect}"
  end

  # ---- the sockets -------------------------------------------------------------------------------

  def smb_port = @smb.addr[1]

  # A port nothing listens on: bind, read the number, close. (Refused, which is what Tower being
  # down looks like from the VM.)
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Uptime Kuma's own copy-button shape, query string and all — the script must strip it.
  def kuma_url = "http://127.0.0.1:#{@kuma.addr[1]}/api/push/fixture-token?status=up&msg=OK&ping="

  def pinged
    @pinged ||= []
  end

  def respond_to_pings
    @responder = Thread.new do
      loop do
        client = @kuma.accept
        pinged << client.gets.to_s.strip
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def assert_never_pinged(message = nil)
    connection = @kuma.accept_nonblock(exception: false)
    return if connection == :wait_readable

    connection.close
    flunk(message || "the script connected to the Kuma URL, and this mode must never ping")
  end

  # ---- running the script under the fakes -------------------------------------------------------

  def run_script(*args, smb_port: nil)
    env = { "PATH" => "#{@bin}:/usr/bin:/bin", "HOME" => @home, "LANG" => "C",
            "FAKE_STATE" => @state, "SMB_PORT" => (smb_port || closed_port).to_s }
    Open3.capture3(env, "/bin/bash", SCRIPT.to_s, *args, unsetenv_others: true, chdir: @home)
  end

  def write_fakes
    fake "docker", <<~'SH'
      #!/bin/bash
      s="$FAKE_STATE"
      echo "$*" >> "$s/calls.log"
      case "$*" in
        "ps --filter name=^tinkerex-web-share- --filter status=running --format {{.ID}} {{.Names}}")
          cat "$s/running" 2>/dev/null; exit 0 ;;
        "ps -a --filter name=^tinkerex-web-share- --filter status=created --format {{.ID}} {{.Names}}")
          cat "$s/created" 2>/dev/null; exit 0 ;;
        "exec "*" ls /library")
          case "$(cat "$s/ls.$2" 2>/dev/null || echo ok)" in
            ok)     exit 0 ;;
            stale)  echo "ls: cannot access '/library': Stale file handle" >&2; exit 2 ;;
            denied) echo "ls: cannot open directory '/library': Permission denied" >&2; exit 2 ;;
            hang)   exit 124 ;;
          esac ;;
        "inspect --format "*)
          echo tinkerex_library_3dprinting ;;
        "volume inspect --format {{.Options.device}} tinkerex_library_3dprinting")
          echo "//127.0.0.1/3D Printing" ;;
        "volume inspect --format {{.Mountpoint}} tinkerex_library_3dprinting")
          echo "/var/lib/docker/volumes/tinkerex_library_3dprinting/_data" ;;
        "stop "*)
          grep -v "^$2 " "$s/running" > "$s/running.tmp" 2>/dev/null || true; mv "$s/running.tmp" "$s/running"
          [ -e "$s/stop_releases" ] && rm -f "$s/mounted"; exit 0 ;;
        "rm "*)
          grep -v "^$2 " "$s/created" > "$s/created.tmp" 2>/dev/null || true; mv "$s/created.tmp" "$s/created"; exit 0 ;;
        *) echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
      esac
    SH
    fake "mount", <<~'SH'
      #!/bin/bash
      echo "sysfs on /sys type sysfs (rw,nosuid,nodev,noexec,relatime)"
      [ -e "$FAKE_STATE/mounted" ] && echo "//127.0.0.1/3D Printing on /var/lib/docker/volumes/tinkerex_library_3dprinting/_data type cifs (rw,relatime,vers=3.0,sec=none,cache=strict,uid=1000,gid=1000,soft)"
      exit 0
    SH
    fake "timeout", <<~'SH'
      #!/bin/bash
      shift
      exec "$@"
    SH
    fake "logger", <<~'SH'
      #!/bin/bash
      echo "$*" >> "$FAKE_STATE/logger.log"
    SH
  end

  def fake(name, body)
    path = File.join(@bin, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def kamal_config(destination)
    require "kamal"
    Kamal::Configuration.create_from(config_file: ROOT.join("config/deploy.yml"), destination: destination)
  end
end
