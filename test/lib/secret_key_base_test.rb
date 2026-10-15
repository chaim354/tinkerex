require "test_helper"
require "tmpdir"

# The session secret needs no hand-set value: ENV wins, then the credential, then a file generated
# once into storage/ (the persistent volume). Pure apart from that file, so this test needs no boot
# and drives it against a temp directory; production.rb assigns the result (the design says why).
class SecretKeyBaseTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("secret")
    @messages = []
    @log = ->(m) { @messages << m }
  end

  teardown { FileUtils.remove_entry(@dir) }

  def resolve(env = {}, credential: nil)
    Tinkerex::SecretKeyBase.resolve(env: env, credential: credential, dir: @dir, log: @log)
  end

  def file = File.join(@dir, "secret_key_base")

  test "the environment wins, and a blank value counts as unset" do
    assert_equal "from-env", resolve({ "SECRET_KEY_BASE" => "from-env" })
    assert_not File.exist?(file), "an ENV secret must not write the file"
    assert_match(/\A\h{128}\z/, resolve({ "SECRET_KEY_BASE" => " " }),
                 ".env.example shipped SECRET_KEY_BASE= as a line to fill in; blank is unset")
  end

  test "the credential wins over the file" do
    assert_equal "from-credential", resolve({}, credential: "from-credential")
    assert_not File.exist?(file)
  end

  test "generated once, mode 0600, announced once, reused on the next boot" do
    first = resolve
    assert_match(/\A\h{128}\z/, first)
    assert_equal 0o600, File.stat(file).mode & 0o777
    assert_equal [ first ], [ File.read(file).strip ]
    assert_equal 1, @messages.size
    assert_includes @messages.first, file
    assert_includes @messages.first, "SECRET_KEY_BASE"
    assert_equal first, resolve, "the second boot must read the file, never generate again"
    assert_equal 1, @messages.size, "and say nothing the second time"
  end

  test "an unwritable directory raises, naming the file and the override" do
    skip "root ignores mode bits" if Process.uid.zero?
    FileUtils.chmod(0o500, @dir)
    e = assert_raises(Tinkerex::SecretKeyBase::Error) { resolve }
    assert_includes e.message, file
    assert_includes e.message, "SECRET_KEY_BASE"
  ensure
    FileUtils.chmod(0o700, @dir)
  end

  test "the precompile boot gets nothing, so Rails' own throwaway stands and nothing is written" do
    assert_nil resolve({ "SECRET_KEY_BASE_DUMMY" => "1" })
    assert_not File.exist?(file)
  end
end
