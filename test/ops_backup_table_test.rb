require "test_helper"
require "open3"
require "socket"
require "tmpdir"

# THE BACKUP DESTINATION TABLE IN ops/backup-db.sh, CHECKED AGAINST WHAT IT DESCRIBES AND AGAINST
# WHAT READS IT. This is the first test to run anything under ops/. The rest of the backup scripts
# stays ungated (docs/invariants/backup-restore.md): they run on the box, under cron, against real
# volumes, and you find out they are broken when you need a restore. What a checkout CAN check, with
# no vault, no docker and no network, is the TABLE: which destinations exist, which container's
# image backs each one up, and which volume each one reads (and bin/restore-db writes back into).
# Before the table those facts were spelled out five times across two files, and the copies
# drifted. `sync` was backed up nightly but never pinged, because the ping.env whitelist had no arm
# for it, and bin/restore-db kept a private copy of every volume name.
#
# SAFETY IS BUILT IN. The script runs here ONLY in its read-only modes, `--list` and `--describe`,
# which print from the table and exit in the argument loop before any docker call or ping. The
# environment is built from nothing (PATH=/usr/bin:/bin, a temp HOME, no KAMAL_*, no secret), and
# every URL in the fixture ping.env points at a socket THIS TEST owns. A mode that ever did ping
# would be caught here, never heard by a monitor. The other backup scripts are only READ. The
# interpreter is /bin/bash on purpose: on a Mac it is 3.2, which is the bash bin/restore-db's
# `--describe` call meets there.
class OpsBackupTableTest < ActiveSupport::TestCase
  ROOT = Rails.root
  SCRIPT = ROOT.join("ops/backup-db.sh")
  # Every script that reaches the box over ssh. Each defaults DEPLOY_HOST to the box.
  BOX_SCRIPTS = %w[bin/backup-db bin/restore-db bin/backup-status bin/backup-cron-install].freeze

  # Where the app image keeps its SQLite databases: the image's WORKDIR is /rails (Dockerfile), and
  # config/database.yml puts production's under storage/. The volume mounted HERE is the one a
  # destination's backup reads. share's second mount, /library, is the user's NAS share itself.
  APP_STORAGE = "/rails/storage"

  # ACCESSORY VOLUMES ON THE BOX THAT THE NIGHTLY DELIBERATELY DOES NOT TAKE, each with its reason.
  # The exception is data, so a new accessory volume must land in the table or here, with an
  # argument. It can never silently land in neither.
  NOT_BACKED_UP = {
    "openscad" => "openscad-cache is a render cache; losing it costs only the first render of each design"
  }.freeze

  # A Kamal version is a git SHA, and a filter must find the container whichever character the SHA
  # starts with. So one sample starts with a digit and one with a letter; chunk's `[0-9a-f]` exists
  # for exactly this.
  SAMPLE_VERSIONS = %w[0d8f6b4a2c9e7f5d3b1a0c8e6f4d2b9a7c5e3f1d e6a4c2f0d8b6a9c7e5f3d1b0a8c6e4f2d0b9a7c5].freeze
  # `docker ps -a` still lists these on the box, and no row may match one. They are the exited
  # containers of the old standalone tinkerex-sync deployment (ops/backup-db.sh says why, beside
  # the sync row).
  FOREIGN_CONTAINERS = SAMPLE_VERSIONS.map { |version| "tinkerex-sync-web-#{version}" }.freeze

  setup do
    @home = Dir.mktmpdir("ops-backup-table")
    @listener = TCPServer.new("127.0.0.1", 0)
  end

  teardown do
    @listener.close
    FileUtils.remove_entry(@home)
  end

  test "--list prints the table: one bare destination name per line, and nothing else" do
    out, err, status = backup_db("--list")
    assert status.success?, "ops/backup-db.sh --list failed (#{status.exitstatus}): #{err}"
    assert_empty err

    names = out.lines(chomp: true)
    refute_empty names, "--list printed nothing, so the table parse is broken and every test here is vacuous"
    # A name must be a BARE word because it becomes three other things: the ping.env key
    # PING_<NAME>, the archive name tinkerex-<name>-<stamp>.tar.gz that the prune GLOBS, and a token
    # in the crontab line that bin/backup-status word-splits. A `#`, a space or a glob character
    # breaks each of those in a different way.
    names.each do |name|
      assert_match(/\A[a-z][a-z0-9]*\z/, name, "--list printed #{name.inspect}, which is not a bare destination name")
    end
    assert_equal names.uniq, names, "a destination is listed twice"
  end

  test "--describe answers for every listed destination with the fields its callers read" do
    table_names.each do |name|
      fields = describe(name)
      # bin/restore-db reads container_filter and volume BY KEY, so a renamed key makes every restore
      # refuse to start. That refusal is its guard against an empty filter, which `docker ps -a -qf
      # name=` would answer with EVERY container on the box.
      assert_equal %w[container_filter name ping_configured ping_key volume], fields.keys.sort, "--describe #{name}"
      assert_equal name, fields["name"]
      assert_equal "PING_#{name.upcase}", fields["ping_key"],
                   "--describe #{name}: the key must be spelled the way bin/backup-cron-install writes it into ping.env"
      refute_empty fields["container_filter"], "--describe #{name}"
      assert_match(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]+\z/, fields["volume"], "--describe #{name}: not a docker volume name")
      assert_includes %w[yes no], fields["ping_configured"], "--describe #{name}"
    end
  end

  test "every database the box runs has exactly one row, and every row is exactly one database the box runs" do
    subjects = box_subjects
    rows = table_rows
    # NON-VACUOUS FIRST (§14e). The base destination IS the box, so if the derivation finds nothing
    # there, the derivation is broken and everything below would be checking an empty set.
    assert subjects.any? { |subject| subject[:source] == "config/deploy.yml" },
           "the base destination's app is not on the box the backup scripts ssh to; is box_host reading the wrong thing?"
    refute_empty rows, "the table has no rows"

    problems = []
    subjects.each do |subject|
      covering = rows.select { |row| subject[:names].any? { |name| matches?(row, name) } }
      if covering.empty?
        problems << "#{subject[:source]} runs #{subject[:names].first} on the box with its databases in " \
                    "#{subject[:volumes].join(' / ')}, and no row of ops/backup-db.sh's destination table backs " \
                    "it up. The nightly never takes it, and bin/restore-db cannot restore it."
      elsif covering.size > 1
        problems << "rows #{covering.map { |row| row[:name] }.join(', ')} all match #{subject[:names].first}. " \
                    "`head -1` would pick one of them, and bin/restore-db would stop whichever it picked."
      else
        row = covering.first
        missed = subject[:names].reject { |name| matches?(row, name) }
        if missed.any?
          problems << "row #{row[:name]} (#{row[:filter]}) misses #{missed.join(', ')}, so a deploy whose " \
                      "SHA starts that way is skipped"
        end
        if subject[:volumes].size != 1
          problems << "#{subject[:source]} mounts #{subject[:volumes].inspect} where its databases live; which one does a backup read?"
        elsif row[:volume] != subject[:volumes].first
          problems << "row #{row[:name]} reads volume #{row[:volume]}, but #{subject[:source]} keeps its databases in " \
                      "#{subject[:volumes].first}. The backup would archive the wrong volume, and a restore would " \
                      "create an empty one of the wrong name and restore into it."
        end
      end
    end
    rows.each do |row|
      matched = subjects.select { |subject| subject[:names].any? { |name| matches?(row, name) } }
      if matched.empty?
        problems << "row #{row[:name]} (#{row[:filter]}) matches no container the deploy config runs on the box"
      elsif matched.size > 1
        problems << "row #{row[:name]} (#{row[:filter]}) matches the containers of #{matched.map { |s| s[:source] }.join(', ')}"
      end
      FOREIGN_CONTAINERS.each do |foreign|
        problems << "row #{row[:name]} (#{row[:filter]}) also matches #{foreign}, an exited container of the old standalone sync deployment" if matches?(row, foreign)
      end
    end

    stale = NOT_BACKED_UP.keys - box_accessory_volumes.keys
    problems << "NOT_BACKED_UP names #{stale.join(', ')}, which is no longer an accessory with a volume on the box" if stale.any?

    assert_empty problems, problems.join("\n")
  end

  test "an unknown destination is refused with a usage error read off the table, and no read-only mode pings" do
    # Every run's fixture ping.env holds a URL for each table row AND for `nonesuch`, all pointing at
    # this test's socket. backup_db fails if any run so much as connects.
    [ %w[--describe nonesuch], %w[--describe] ].each do |args|
      out, err, status = backup_db(*args)
      assert_equal 64, status.exitstatus, "ops/backup-db.sh #{args.join(' ')} should be a usage error: #{err}"
      assert_empty out, "a refused --describe must print no row for a caller to parse"
      assert_includes err, "unknown destination"
      assert_includes err, table_names.join("|"),
                      "the refusal must name the destinations the TABLE has. This file's last hand-kept list is how it went stale."
    end
  end

  test "a row is all a destination's ping needs: exactly the line PING_<NAME>= is read, and the last one wins" do
    names = table_names
    # THE 2026-08-26 REGRESSION, CHECKED FOR EVERY ROW. A ping.env holding ONLY one destination's
    # line must make exactly that destination pingable. `sync` was accepted and backed up while the
    # old enumerated whitelist had no arm for it, so its line was never read. The URL is Uptime
    # Kuma's own copy-button shape, `?status=up&msg=OK&ping=`, `&` and all.
    names.each do |only|
      answers = names.to_h { |name| [ name, describe(name, ping_lines: [ "PING_#{only.upcase}=#{kuma_url}" ])["ping_configured"] ] }
      assert_equal names.to_h { |name| [ name, name == only ? "yes" : "no" ] }, answers,
                   "with ping.env holding only PING_#{only.upcase}, only #{only} may be pingable"
    end

    # Only a line BEGINNING with exactly `PING_<NAME>=` counts, and the last such line wins.
    key = "PING_#{names.first.upcase}"
    { [ "  #{key}=#{kuma_url}" ] => "no",
      [ "export #{key}=#{kuma_url}" ] => "no",
      [ "#{key}X=#{kuma_url}" ] => "no",
      [ "#{key}=#{kuma_url}", "#{key}=" ] => "no",
      [ "#{key}=", "#{key}=#{kuma_url}" ] => "yes" }.each do |lines, expected|
      assert_equal expected, describe(names.first, ping_lines: lines)["ping_configured"], "ping.env: #{lines.inspect}"
    end
  end

  test "ping.env is parsed, never sourced: a value is read literally and never executed" do
    # Sourcing ping.env would run this line. Parsed, the line is just a non-empty value. (Sourcing
    # would also turn every `&` in a Kuma URL into a job separator, which the test above catches
    # separately.)
    name = table_names.first
    sentinel = File.join(@home, "sourced")
    answer = describe(name, ping_lines: [ "PING_#{name.upcase}=$(touch #{sentinel})`touch #{sentinel}`" ])["ping_configured"]
    assert_not File.exist?(sentinel), "ping.env was EXECUTED. It must be parsed, never sourced."
    assert_equal "yes", answer
  end

  test "bin/restore-db reads its container filter and volume from the table and keeps no copy" do
    code = code_lines("bin/restore-db").map(&:last)
    assert code.any? { |line| line.include?("ops/backup-db.sh") }, "bin/restore-db no longer names ops/backup-db.sh"
    assert code.any? { |line| line.include?("--describe") }, "bin/restore-db no longer asks the table with --describe"

    # A restore must write back into the volume the backup READ. A private copy here drifts silently:
    # `docker volume create` makes an EMPTY volume of the stale name, the restore goes into it, the
    # container restarts on its REAL volume, and a rehearsal verifies the wrong one.
    copies = table_rows.flat_map { |row| code.grep(/(?<![\w-])#{Regexp.escape(row[:volume])}(?![\w-])/) }
    copies += code.grep(/\b(?:FILTER|VOLUME)=['"]?[\^\w]/)
    assert_empty copies, "bin/restore-db spells a destination's volume or container filter itself again:\n  #{copies.join("\n  ")}"
  end

  test "no backup script spells out the destination list except bin/backup-status, whose two copies must match the table" do
    names = table_names
    word = names.map { |name| Regexp.escape(name) }.join("|")
    list = %r{(?<![\w./-])(?:#{word})(?:[ |+,](?:#{word}))+(?![\w./-])}
    readers = %w[ops/backup-db.sh bin/backup-db bin/restore-db bin/backup-cron-install]
    spelled = readers.flat_map do |rel|
      code_lines(rel).filter_map { |number, line| "#{rel}:#{number}: #{line.strip}" if line.match?(list) }
    end
    assert_empty spelled, "these read the table, so a destination list of their own is a second copy waiting to go stale:\n  " \
                          "#{spelled.join("\n  ")}"

    # bin/backup-status's two copies run ON THE BOX, inside an ssh heredoc, where the checkout's table
    # cannot be read. So they stay spelled out, and this test holds them to the table instead.
    source = ROOT.join("bin/backup-status").read
    closed = source[/^\s*([a-z0-9|]+)\)\s*line_dests=/, 1]
    fallback = source[/line_dests:-([a-z0-9 ]+)\}/, 1]
    assert closed && fallback,
           "could not find bin/backup-status's closed set and fallback. Did they move? This guard is blind until it finds them again."
    { "closed set (the destinations its crontab parse accepts)" => closed.split("|"),
      "fallback (used when the crontab line cannot be read)" => fallback.split }.each do |what, listed|
      assert_equal names.sort, listed.sort,
                   "bin/backup-status's #{what} lists #{listed.join(' ')}, but ops/backup-db.sh's table has " \
                   "#{names.join(' ')}. This enumeration has gone stale."
    end
  end

  private

  # Runs ops/backup-db.sh in a sandbox, then fails if anything connected to this test's ping socket.
  # The default ping.env holds a Kuma-shaped URL for every table row and for `nonesuch`, so a ping
  # attempt from any mode would find a URL to use.
  def backup_db(*args, ping_lines: nil)
    ping_lines ||= (table_names + [ "nonesuch" ]).map { |name| "PING_#{name.upcase}=#{kuma_url}" }
    ping_file = File.join(@home, "ping.env")
    File.write(ping_file, ping_lines.map { |line| "#{line}\n" }.join)
    env = { "PATH" => "/usr/bin:/bin", "HOME" => @home, "PING_FILE" => ping_file, "LANG" => "C" }
    out, err, status = Open3.capture3(env, "/bin/bash", SCRIPT.to_s, *args, unsetenv_others: true, chdir: @home)

    connection = @listener.accept_nonblock(exception: false)
    if connection != :wait_readable
      connection.close
      flunk "ops/backup-db.sh #{args.join(' ')} connected to the ping.env URL. --list and --describe must never ping."
    end
    [ out, err, status ]
  end

  def table_names
    @table_names ||= begin
      out, err, status = backup_db("--list", ping_lines: [])
      assert status.success?, "ops/backup-db.sh --list failed (#{status.exitstatus}): #{err}"
      out.lines(chomp: true)
    end
  end

  def describe(name, ping_lines: nil)
    out, err, status = backup_db("--describe", name, ping_lines: ping_lines)
    assert status.success?, "ops/backup-db.sh --describe #{name} failed (#{status.exitstatus}): #{err}"
    out.lines(chomp: true).to_h { |line| line.split("=", 2) }
  end

  def table_rows
    table_names.map do |name|
      fields = describe(name)
      { name: name, filter: fields.fetch("container_filter"), volume: fields.fetch("volume") }
    end
  end

  def kuma_url
    "http://127.0.0.1:#{@listener.addr[1]}/api/push/fixture-token?status=up&msg=OK&ping="
  end

  # docker's `name=` filter is a Go regexp over the container's name. These patterns (anchors, one
  # bracket class, literals) mean the same thing in Ruby.
  def matches?(row, container)
    Regexp.new(row[:filter]).match?(container)
  end

  # Full-line comments are skipped, because some keep a PARTIAL destination list on purpose, as
  # evidence. bin/backup-status quotes the list a glob bug once produced.
  def code_lines(rel)
    ROOT.join(rel).readlines(chomp: true).each_with_index.filter_map do |line, index|
      [ index + 1, line ] unless line.lstrip.start_with?("#")
    end
  end

  # The box the nightly runs on: the host every backup script's ssh defaults to. They must agree,
  # because an ad-hoc backup going to one box while the nightly runs on another is a bug of its own.
  def box_host
    defaults = BOX_SCRIPTS.to_h { |rel| [ rel, ROOT.join(rel).read[/DEPLOY_HOST:-([^}]+)\}/, 1] ] }
    missing = defaults.select { |_, host| host.nil? }.keys
    assert_empty missing, "no DEPLOY_HOST default found in #{missing.join(', ')}. Did the ssh target move?"
    assert_equal 1, defaults.values.uniq.size, "the backup scripts disagree about which box they reach: #{defaults.inspect}"
    defaults.values.first.split("@").last
  end

  def kamal_config(destination)
    require "kamal"
    Kamal::Configuration.create_from(config_file: ROOT.join("config/deploy.yml"), destination: destination)
  end

  # STRING keys: raw_config answers dig("volumes") and not dig(:volumes) (test/deploy_hygiene_test.rb's `at`).
  def at(node, *path)
    path.reduce(node) { |value, key| value.is_a?(Hash) ? value[key] : nil }
  end

  # Accessories are never overlaid, so the base config's accessories belong to every destination.
  def box_accessory_volumes
    base = kamal_config(nil)
    box = box_host
    base.accessories.each_with_object({}) do |accessory, found|
      next unless accessory.hosts.include?(box)

      volumes = Array(at(base.raw_config, "accessories", accessory.name.to_s, "volumes")).map { |spec| spec.split(":").first }
      found[accessory.name.to_s] = { service: accessory.service_name, volumes: volumes } if volumes.any?
    end
  end

  # WHAT THE MERGED KAMAL CONFIG RUNS ON THE BOX THAT HOLDS A DATABASE. This is derived, never
  # listed, so a destination added under config/ becomes a backup subject before anyone remembers to
  # add it here. Every destination file counts except *.example.yml, which is an example and not a
  # destination. Only destinations whose app runs ON the box count: OVH runs on a host of its own,
  # which the nightly cannot reach.
  def box_subjects
    box = box_host
    destinations = [ nil ] + Dir.glob("config/deploy.*.yml", base: ROOT)
                                 .map { |file| file[%r{\Aconfig/deploy\.(.+)\.yml\z}, 1] }
                                 .reject { |destination| destination.end_with?(".example") }
    apps = destinations.filter_map do |destination|
      config = kamal_config(destination)
      role = config.primary_role
      next unless role.hosts.include?(box)

      mounts = Array(at(config.raw_config, "volumes")).map { |spec| spec.split(":") }
      { source: "config/deploy#{".#{destination}" if destination}.yml",
        names: SAMPLE_VERSIONS.map { |version| role.container_name(version) },
        volumes: mounts.select { |_, path| path == APP_STORAGE }.map(&:first) }
    end
    accessories = box_accessory_volumes.except(*NOT_BACKED_UP.keys).map do |name, accessory|
      { source: "config/deploy.yml's #{name} accessory", names: [ accessory[:service] ], volumes: accessory[:volumes] }
    end
    apps + accessories
  end
end
