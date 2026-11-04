require "test_helper"
require "open3"
require "socket"
require "tmpdir"

# ops/library-check.sh — THE SHARE LIBRARY'S MOUNT CHECK — DRIVEN END TO END AGAINST A FAKE DOCKER
# AND A FAKE UPTIME KUMA. The script runs on the box under cron, where nothing in bin/ci can see it,
# and the failure it exists for (a stale CIFS mount while /up stays 200, tinkerex#499) was silent
# three times. So the decision it makes is checked here, not trusted: a library that lists is `up`,
# one that errors, hangs, reads EMPTY or has no running container is `down`, and only `--ping`
# ever reaches the monitor.
#
# THE FAKE DOCKER IS A REAL-FILESYSTEM ONE. `docker exec <id> …` runs its command on THIS machine
# with every absolute path re-rooted under a per-container directory, so the healthy case is a real
# `ls` of real files and the unreadable case is a real `ls` failing on a path that is not there —
# the stale mount's shape (ls exits 2 with its error on stderr), which no Mac or CI runner can
# produce for real. It also DRAINS STDIN, as any stdin-reading command would: under the deploy
# skill's `ssh … bash -s < ops/library-check.sh` the rest of the script is stdin, and a docker call
# that read it would silently end the check.
#
# SAFETY: the environment is built from nothing (no real docker on PATH ahead of the fake, a temp
# HOME, no KAMAL_*), and every push URL points at a socket this test owns.
class OpsLibraryCheckTest < ActiveSupport::TestCase
  ROOT = Rails.root
  SCRIPT = ROOT.join("ops/library-check.sh")
  INSTALLER = ROOT.join("bin/library-check-install")
  DEPLOY_SKILL = ROOT.join(".claude/commands/deploy.md")
  # A Kamal version is a git SHA; one sample starts with a digit and one with a letter, so a filter
  # that only works for one of them fails here (test/ops_backup_table_test.rb's reasoning).
  SAMPLE_VERSIONS = %w[0d8f6b4a2c9e7f5d3b1a0c8e6f4d2b9a7c5e3f1d e6a4c2f0d8b6a9c7e5f3d1b0a8c6e4f2d0b9a7c5].freeze
  CID = "cf9340670966".freeze
  CONTAINER = "tinkerex-web-share-#{SAMPLE_VERSIONS.first}".freeze

  FAKE_DOCKER = <<~'SH'.freeze
    #!/bin/bash
    # Fake docker for test/ops_library_check_test.rb. State lives in $FAKE_DOCKER:
    #   containers           "id name" per RUNNING container
    #   fs/<id>/             that container's filesystem root
    #   exec_status_<id>     `docker exec` exits with this status, running nothing (124 = timed out)
    #   ps_fails             `docker ps` fails as an unreachable daemon does
    #   volume / device      the volume mounted at the checked path, and its device option
    cat >/dev/null
    fake=$FAKE_DOCKER
    case "$1" in
      ps)
        if [ -e "$fake/ps_fails" ]; then echo "Cannot connect to the Docker daemon" >&2; exit 1; fi
        filter=""
        while [ $# -gt 0 ]; do
          case "$1" in --filter) filter=${2#name=}; shift 2 ;; *) shift ;; esac
        done
        [ -f "$fake/containers" ] || exit 0
        FILTER="$filter" awk '$2 ~ ENVIRON["FILTER"] { print $1 }' "$fake/containers" ;;
      inspect)
        case "$3" in
          *Mounts*) if [ -f "$fake/volume" ]; then cat "$fake/volume"; else echo; fi ;;
          *) ID="$4" awk '$1 == ENVIRON["ID"] { print "/" $2 }' "$fake/containers" ;;
        esac ;;
      volume)
        if [ -f "$fake/device" ]; then cat "$fake/device"; else echo "<no value>"; fi ;;
      exec)
        id=$2; shift 2
        if [ -f "$fake/exec_status_$id" ]; then exit "$(cat "$fake/exec_status_$id")"; fi
        args=()
        for a in "$@"; do
          case "$a" in /*) args+=("$fake/fs/$id$a") ;; *) args+=("$a") ;; esac
        done
        exec "${args[@]}" ;;
      *) echo "fake docker: unexpected $*" >&2; exit 99 ;;
    esac
  SH

  # macOS has no `timeout`, and the real one would only add a duration this test never waits out. An
  # expired timeout is the fake docker's exec_status_<id> = 124.
  FAKE_TIMEOUT = <<~'SH'.freeze
    #!/bin/bash
    while [ $# -gt 0 ]; do
      case "$1" in -k|-s) shift 2 ;; -*) shift ;; *) break ;; esac
    done
    shift
    exec "$@"
  SH

  setup do
    @home = Dir.mktmpdir("ops-library-check")
    @fake = File.join(@home, "docker")
    @bin = File.join(@home, "bin")
    FileUtils.mkdir_p([ @fake, @bin ])
    { "docker" => FAKE_DOCKER, "timeout" => FAKE_TIMEOUT }.each do |name, body|
      File.write(File.join(@bin, name), body)
      File.chmod(0o755, File.join(@bin, name))
    end
    @ping_file = File.join(@home, "library-ping.env")
    @kuma = FakeKuma.new
    @smb = TCPServer.new("127.0.0.1", 0)
    @smb_port = @smb.addr[1]
    write_ping_file("PING_LIBRARY_SHARE=#{@kuma.url}")
    run_container(CID, CONTAINER, entries: %w[catan whole .trash])
  end

  teardown do
    @kuma.close
    @smb.close unless @smb.closed?
    FileUtils.remove_entry(@home)
  end

  test "a library that lists is up, and says how many entries it saw" do
    out, err, status = check("--ping")

    assert_equal 0, status.exitstatus, "a readable library must exit 0: #{out}#{err}"
    assert_match(/ ok  share  #{CONTAINER}: 3 entries in \/library$/, out)
    assert_equal [ "up" ], @kuma.statuses
    assert_includes @kuma.params.first["msg"], "3 entries in /library"
  end

  test "an unreadable library is down, with the listing's own error" do
    # THE FAKE UNREADABLE PATH: the container's /library is not there at all, so `ls` fails exactly
    # as it does on a stale handle — status 2, the reason on stderr.
    FileUtils.rm_rf(File.join(@fake, "fs", CID, "library"))

    out, _err, status = check("--ping")

    assert_equal 1, status.exitstatus, "an unreadable library must exit 1: #{out}"
    assert_match(/ !!  share  #{CONTAINER}: ls: .*library.*No such file or directory/, out)
    assert_equal [ "down" ], @kuma.statuses
    assert_match(/No such file or directory/, @kuma.params.first["msg"])
  end

  test "an EMPTY library is down, because an unmounted mount point is an empty directory" do
    library = File.join(@fake, "fs", CID, "library")
    FileUtils.rm_rf(library)
    FileUtils.mkdir_p(library)

    out, _err, status = check("--ping")

    assert_equal 1, status.exitstatus, out
    assert_includes out, "/library is EMPTY"
    assert_equal [ "down" ], @kuma.statuses
  end

  test "a listing that does not answer is down, not waited on" do
    File.write(File.join(@fake, "exec_status_#{CID}"), "124")

    out, _err, status = check("--ping")

    assert_equal 1, status.exitstatus, out
    assert_includes out, "/library did not answer within 20 s"
    assert_equal [ "down" ], @kuma.statuses
  end

  test "no running container, or no docker, is down: a check that saw nothing must not say all-clear" do
    File.write(File.join(@fake, "containers"), "")
    out, _err, status = check("--ping")
    assert_equal 1, status.exitstatus, out
    assert_includes out, "no running container matches ^tinkerex-web-share-"

    run_container(CID, CONTAINER, entries: %w[catan])
    FileUtils.touch(File.join(@fake, "ps_fails"))
    out, _err, status = check("--ping")
    assert_equal 1, status.exitstatus, out
    assert_includes out, "docker did not answer: Cannot connect to the Docker daemon"

    assert_equal %w[down down], @kuma.statuses
  end

  test "during a deploy both containers are checked, and either one's dead mount is a dead library" do
    other = "a1b2c3d4e5f6"
    run_container(other, "tinkerex-web-share-#{SAMPLE_VERSIONS.last}", entries: [])
    FileUtils.rm_rf(File.join(@fake, "fs", other, "library"))

    out, _err, status = check("--ping")

    assert_equal 1, status.exitstatus, out
    assert_includes out, "tinkerex-web-share-#{SAMPLE_VERSIONS.last}: ls:"
    assert_equal [ "down" ], @kuma.statuses, "one ping per deployment, whatever the number of containers"
  end

  test "a down message says whether the SMB host answers yet, read off the volume's own device" do
    FileUtils.rm_rf(File.join(@fake, "fs", CID, "library"))
    File.write(File.join(@fake, "volume"), "tinkerex_library_3dprinting\n")
    File.write(File.join(@fake, "device"), "//127.0.0.1/3D Printing\n")

    out, = check
    assert_includes out, "SMB 127.0.0.1:#{@smb_port} answers — recover now: docs/DEPLOY.md §6b"

    @smb.close
    out, = check
    assert_includes out, "SMB 127.0.0.1:#{@smb_port} does NOT answer"

    File.delete(File.join(@fake, "device"))
    out, = check
    assert_includes out, "volume tinkerex_library_3dprinting has no device option: it is a PLAIN LOCAL volume"
  end

  test "without --ping nothing reaches the monitor, in either direction" do
    out, _err, status = check
    assert_equal 0, status.exitstatus, out
    FileUtils.rm_rf(File.join(@fake, "fs", CID, "library"))
    out, _err, status = check("--quiet")
    assert_equal 1, status.exitstatus, out

    assert_empty @kuma.statuses, "an ad-hoc run pinged the monitor, so a dead cron could be refreshed by hand"
  end

  test "--quiet says nothing while healthy and still says it when not" do
    out, err, status = check("--ping", "--quiet")
    assert_equal 0, status.exitstatus, err
    assert_empty out, "a healthy cron run must not grow the log every 5 minutes"
    assert_empty err

    FileUtils.rm_rf(File.join(@fake, "fs", CID, "library"))
    out, = check("--ping", "--quiet")
    assert_includes out, " !!  share  "
  end

  test "Kuma's own copy-button URL sends exactly one status" do
    # The UI hands out `…/api/push/TOKEN?status=up&msg=OK&ping=`. Left on, curl --get appends a SECOND
    # status, Kuma reads the pair as an array, and every `down` is recorded as UP.
    write_ping_file("PING_LIBRARY_SHARE=#{@kuma.url}?status=up&msg=OK&ping=")
    FileUtils.rm_rf(File.join(@fake, "fs", CID, "library"))

    check("--ping")

    assert_equal 1, @kuma.requests.size
    assert_equal [ "down" ], @kuma.query_values("status"), "the request line was #{@kuma.requests.first}"
  end

  test "the push file is parsed, never sourced, and only the exact key's last line counts" do
    sentinel = File.join(@home, "sourced")
    write_ping_file("PING_LIBRARY_SHARE=$(touch #{sentinel})`touch #{sentinel}`")
    check("--ping")
    assert_not File.exist?(sentinel), "library-ping.env was EXECUTED. It must be parsed, never sourced."

    # The backup's key for the same deployment is PING_SHARE, and it must ping nothing here.
    { [ "PING_SHARE=#{@kuma.url}" ] => 0,
      [ "  PING_LIBRARY_SHARE=#{@kuma.url}" ] => 0,
      [ "PING_LIBRARY_SHARE=#{@kuma.url}", "PING_LIBRARY_SHARE=" ] => 0,
      [ "PING_LIBRARY_SHARE=", "PING_LIBRARY_SHARE=#{@kuma.url}" ] => 1 }.each do |lines, expected|
      @kuma.reset
      write_ping_file(*lines)
      _out, err, status = check("--ping")
      assert_equal 0, status.exitstatus
      assert_equal expected, @kuma.requests.size, "library-ping.env: #{lines.inspect}"
      assert_includes err, "nothing will hear this" if expected.zero?
    end
  end

  test "a failed ping never changes the answer" do
    dead = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{dead.addr[1]}/api/push/fixture-token"
    dead.close
    write_ping_file("PING_LIBRARY_SHARE=#{url}")

    out, err, status = check("--ping")

    assert_equal 0, status.exitstatus, "Kuma being down turned a readable library into a failed check: #{out}#{err}"
    assert_includes err, "uptime-kuma ping failed for share"
  end

  test "it runs whole under `ssh … bash -s < ops/library-check.sh`, the way the deploy skill runs it" do
    out, err, status = Open3.capture3(env, "/bin/bash", "-s", stdin_data: SCRIPT.read, unsetenv_others: true, chdir: @home)

    assert_equal 0, status.exitstatus, "#{out}#{err}"
    assert_match(/ ok  share  /, out, "the check ended early, so something it ran read the rest of the script from stdin")
    assert_empty @kuma.statuses
  end

  test "every invocation of the script is one it accepts, and only cron's pings" do
    invocations = {
      "bin/library-check-install" => INSTALLER.read.scan(/library-check\.sh((?: --[a-z]+)*)/).map(&:first),
      ".claude/commands/deploy.md" => DEPLOY_SKILL.read.scan(/bash -s(?: --((?: --?[a-z]+)*))? < ops\/library-check\.sh/).map { |m| m.first.to_s }
    }
    invocations.each { |file, found| refute_empty found, "#{file} no longer runs ops/library-check.sh, so this check is blind" }

    invocations.each do |file, found|
      found.each do |flags|
        @kuma.reset
        _out, err, status = check(*flags.split)
        assert_not_equal 64, status.exitstatus, "#{file} runs `library-check.sh#{flags}`, which the script refuses: #{err}"
      end
    end
    assert invocations["bin/library-check-install"].any? { |flags| flags.split.include?("--ping") },
           "the installed cron line must ping, or the monitor never hears from it"
    assert invocations[".claude/commands/deploy.md"].none? { |flags| flags.include?("--ping") },
           "the deploy skill's pre-check must not ping: a hand-run `up` would refresh the heartbeat over a dead cron"

    _out, _err, status = check("--bogus")
    assert_equal 64, status.exitstatus
    assert_empty @kuma.statuses
  end

  test "the table watches every share deployment on the box, at its LIBRARY_PATH, and nothing else" do
    rows = table_rows
    deployments = box_deployments
    shares = deployments.select { |d| d[:backend] == "share" }
    # NON-VACUOUS FIRST (§14e): config/deploy.share.yml is a share deployment on this box, so finding
    # none means the derivation is broken and everything below would check an empty set.
    assert shares.any? { |d| d[:source] == "config/deploy.share.yml" },
           "no share deployment found on #{box_host}; is the derivation reading the wrong thing?"
    refute_empty rows, "--table printed no rows"

    problems = []
    shares.each do |share|
      covering = rows.select { |row| share[:names].any? { |name| row[:filter].match?(name) } }
      if covering.size != 1
        problems << "#{share[:source]} is a share deployment on the box and #{covering.size} rows of " \
                    "ops/library-check.sh's table watch it (#{covering.map { |r| r[:name] }.join(', ')})"
        next
      end
      row = covering.first
      missed = share[:names].reject { |name| row[:filter].match?(name) }
      problems << "row #{row[:name]} (#{row[:filter].source}) misses #{missed.join(', ')}" if missed.any?
      if row[:path] != share[:library_path]
        problems << "row #{row[:name]} lists #{row[:path]}, but #{share[:source]} reads its library from LIBRARY_PATH=#{share[:library_path].inspect}"
      end
      unless share[:mount_targets].include?(row[:path])
        problems << "#{share[:source]} mounts nothing at #{row[:path]}, so listing it checks the container's own disk"
      end
    end
    rows.each do |row|
      matched = deployments.select { |d| d[:names].any? { |name| row[:filter].match?(name) } }
      unless matched.size == 1 && matched.first[:backend] == "share"
        problems << "row #{row[:name]} (#{row[:filter].source}) matches #{matched.map { |d| "#{d[:source]} (#{d[:backend]})" }.inspect}; " \
                    "it must match exactly one share deployment"
      end
    end

    assert_empty problems, problems.join("\n")
  end

  private

  def env
    { "PATH" => "#{@bin}:/usr/bin:/bin", "HOME" => @home, "LANG" => "C", "FAKE_DOCKER" => @fake,
      "LIBRARY_PING_FILE" => @ping_file, "LIBRARY_SMB_PORT" => @smb_port.to_s }
  end

  def check(*args)
    Open3.capture3(env, "/bin/bash", SCRIPT.to_s, *args, unsetenv_others: true, chdir: @home)
  end

  def run_container(id, name, entries:)
    File.open(File.join(@fake, "containers"), "a") { |f| f.puts "#{id} #{name}" }
    library = File.join(@fake, "fs", id, "library")
    FileUtils.mkdir_p(library)
    entries.each { |entry| FileUtils.touch(File.join(library, entry)) }
  end

  def write_ping_file(*lines)
    File.write(@ping_file, lines.map { |line| "#{line}\n" }.join)
  end

  def table_rows
    out, err, status = Open3.capture3({ "PATH" => "/usr/bin:/bin", "HOME" => @home }, "/bin/bash", SCRIPT.to_s, "--table", unsetenv_others: true)
    assert status.success?, "ops/library-check.sh --table failed: #{err}"
    out.lines.map(&:split).map do |name, filter, path|
      # docker's `name=` filter is a Go regexp; these (an anchor and literals) mean the same in Ruby.
      { name:, filter: Regexp.new(filter), path: }
    end
  end

  # The box the check is installed on: the installer's ssh default, which OpsBackupTableTest holds to
  # every other box script's.
  def box_host
    INSTALLER.read[/DEPLOY_HOST:-([^}]+)\}/, 1].to_s.split("@").last.tap do |host|
      assert host.present?, "no DEPLOY_HOST default in bin/library-check-install"
    end
  end

  def kamal_config(destination)
    require "kamal"
    Kamal::Configuration.create_from(config_file: ROOT.join("config/deploy.yml"), destination: destination)
  end

  def at(node, *path)
    path.reduce(node) { |value, key| value.is_a?(Hash) ? value[key] : nil }
  end

  # Every app deployment whose container runs on the box, DERIVED from the merged Kamal config, so a
  # destination added under config/ is held to the table before anyone remembers this test.
  def box_deployments
    destinations = [ nil ] + Dir.glob("config/deploy.*.yml", base: ROOT)
                                 .map { |file| file[%r{\Aconfig/deploy\.(.+)\.yml\z}, 1] }
                                 .reject { |destination| destination.end_with?(".example") }
    destinations.filter_map do |destination|
      config = kamal_config(destination)
      role = config.primary_role
      next unless role.hosts.include?(box_host)

      clear = at(config.raw_config, "env", "clear") || {}
      { source: "config/deploy#{".#{destination}" if destination}.yml",
        backend: clear["LIBRARY_BACKEND"],
        library_path: clear["LIBRARY_PATH"],
        mount_targets: Array(at(config.raw_config, "volumes")).map { |spec| spec.split(":")[1] },
        names: SAMPLE_VERSIONS.map { |version| role.container_name(version) } }
    end
  end

  # An Uptime Kuma that answers every push 200 and remembers what it was sent.
  class FakeKuma
    attr_reader :requests

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @requests = []
      @lock = Mutex.new
      @thread = Thread.new { serve }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}/api/push/fixture-token"
    def reset = @lock.synchronize { @requests.clear }
    def params = requests.map { |line| Rack::Utils.parse_query(line.split[1].to_s.split("?", 2)[1].to_s) }
    def statuses = params.map { |p| p["status"] }
    def query_values(key) = requests.flat_map { |line| URI.decode_www_form(line.split[1].to_s.split("?", 2)[1].to_s).filter_map { |k, v| v if k == key } }

    def close
      @thread.kill
      @server.close
    end

    private

    def serve
      loop do
        client = @server.accept
        line = client.gets.to_s.strip
        while (header = client.gets) && header != "\r\n"; end
        @lock.synchronize { @requests << line }
        client.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end
end
