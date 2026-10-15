require "test_helper"
require "tmpdir"
require "open3"

# bin/docker-entrypoint is bash and nothing in bin/ci runs the image, so the one way to pin what it
# does is to run the script with the three commands it delegates to replaced by recorders on PATH:
# `id` (root or not), `setpriv` (records its arguments, then runs the rest so the unprivileged half
# executes too) and `chown`. The directories are REAL temp directories owned by this process, so the
# "owner differs from PUID:PGID" decision is the real one, in both directions. The root-owned
# empty-library branch needs a root-owned directory and is proved by the Linux run the design
# records (spec §6), not here. The Dockerfile pins at the end are the other half of the same change.
class DockerEntrypointTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/docker-entrypoint")

  setup do
    @root = Dir.mktmpdir("entrypoint")
    %w[bin storage tmp log stubs library].each { |d| FileUtils.mkdir_p(File.join(@root, d)) }
    @entrypoint = File.join(@root, "bin/docker-entrypoint")
    FileUtils.cp(SCRIPT, @entrypoint)
    FileUtils.chmod(0o755, @entrypoint)
    @log = File.join(@root, "calls.log")
    stub("id", %(echo "${ENTRYPOINT_TEST_UID:-0}"))
    stub("chown", %(echo "chown $*" >> "$ENTRYPOINT_LOG"))
    # The real setpriv re-runs the script as a non-root uid; the stub records its arguments, then
    # makes the re-run see a non-root `id -u` (or the script would loop forever) and execs the rest.
    stub("setpriv", %(echo "setpriv $*" >> "$ENTRYPOINT_LOG"; export ENTRYPOINT_TEST_UID=1000; while [ "${1#--}" != "$1" ]; do shift; done; exec "$@"))
    stub("rails", %(echo "rails $*" >> "$ENTRYPOINT_LOG"), dir: "bin")
  end

  teardown { FileUtils.remove_entry(@root) }

  def stub(name, body, dir: "stubs")
    path = File.join(@root, dir, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def run_entrypoint(*cmd, env: {})
    full_env = { "PATH" => "#{File.join(@root, 'stubs')}:#{ENV['PATH']}", "ENTRYPOINT_LOG" => @log,
                 "LIBRARY_PATH" => File.join(@root, "library"), "PUID" => nil, "PGID" => nil }.merge(env)
    out, status = Open3.capture2e(full_env, @entrypoint, *cmd, chdir: @root)
    [ out, status, File.exist?(@log) ? File.readlines(@log, chomp: true) : [] ]
  end

  test "as root: the app's directories become PUID:PGID, the library is left alone, setpriv re-runs the script" do
    out, status, calls = run_entrypoint("./bin/rails", "server", env: { "PUID" => "99", "PGID" => "100" })
    assert status.success?, out
    chowns = calls.grep(/\Achown /)
    ours = chowns.select { |c| c.include?(@root) }
    assert_equal 3, ours.size, "storage, tmp and log: #{calls}"
    ours.each { |c| assert_match(%r{\Achown -R 99:100 #{Regexp.escape(@root)}/(storage|tmp|log)\z}, c) }
    assert_empty chowns - ours - [ "chown -R 99:100 /home/rails" ],
                 "the only directory outside the app root it may chown is /home/rails: #{calls}"
    assert_empty calls.grep(/library/), "the library folder is the user's, never chowned: #{calls}"
    assert_includes calls, "setpriv --reuid=99 --regid=100 --clear-groups #{@entrypoint} ./bin/rails server"
    assert_equal [ "rails db:prepare", "rails server" ], calls.grep(/\Arails /),
                 "the unprivileged half prepares the database, then runs the server"
  end

  test "directories already owned by PUID:PGID are not chowned, and db:prepare runs only for the server" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "PUID" => Process.uid.to_s, "PGID" => Process.gid.to_s })
    assert status.success?, out
    assert_empty calls.grep(/\Achown /), "owner already matches: #{calls}"
    assert_equal 1, calls.grep(/\Asetpriv /).size
    assert_empty calls.grep(/\Arails /)
    assert_equal "hi", out.strip
  end

  test "not root (started with --user): no chown, no setpriv, the command runs as given" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "ENTRYPOINT_TEST_UID" => "501", "PUID" => "99" })
    assert status.success?, out
    assert_equal "hi", out.strip
    assert_empty calls
  end

  test "a PUID that is not a whole number is refused before anything is touched" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "PUID" => "rails" })
    assert_not status.success?
    assert_includes out, "PUID"
    assert_empty calls
  end

  test "the image has no USER line and defaults to the share backend at /library" do
    dockerfile = Rails.root.join("Dockerfile").read
    assert_no_match(/^USER /, dockerfile, "the entrypoint chooses the user at run time")
    assert_match(/^ENV LIBRARY_BACKEND="share"/, dockerfile)
    assert_match(/LIBRARY_PATH="\/library"/, dockerfile)
    assert_includes dockerfile, 'ENTRYPOINT ["/rails/bin/docker-entrypoint"]'
  end
end
