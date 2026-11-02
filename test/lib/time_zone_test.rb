require "test_helper"

# config.time_zone's three answers (lib/tinkerex/time_zone.rb): TIME_ZONE when it names a zone, the
# host's zone when it is unset, UTC always in the test env -- and a TIME_ZONE that names nothing is
# refused in production, never normalised.
class TinkerexTimeZoneTest < ActiveSupport::TestCase
  PRODUCTION = ActiveSupport::EnvironmentInquirer.new("production")
  DEVELOPMENT = ActiveSupport::EnvironmentInquirer.new("development")
  TEST = ActiveSupport::EnvironmentInquirer.new("test")

  setup { @dir = Pathname.new(Dir.mktmpdir("tz")) }
  teardown { FileUtils.remove_entry(@dir) if @dir&.exist? }

  # A dangling symlink is enough: only the link's TEXT is read.
  def localtime_to(target)
    path = @dir.join("localtime")
    File.symlink(target, path)
    path.to_s
  end

  def missing_localtime = @dir.join("absent").to_s

  def resolve(env, rails_env: PRODUCTION, localtime: missing_localtime, log: ->(msg) { (@logged ||= []) << msg })
    Tinkerex::TimeZone.resolve(env:, rails_env:, localtime:, log:)
  end

  test "TIME_ZONE names the zone when it is one" do
    assert_equal "Europe/Berlin", resolve({ "TIME_ZONE" => "Europe/Berlin", "TZ" => "Asia/Tokyo" })
    assert_equal "America/New_York", resolve({ "TIME_ZONE" => "America/New_York" }, rails_env: DEVELOPMENT)
  end

  test "a TIME_ZONE that names no zone refuses a production boot, naming the variable and the value" do
    [ "Mars/Olympus", "america/new_york", " America/New_York", "America/New_York " ].each do |bad|
      error = assert_raises(Tinkerex::TimeZone::Invalid, "#{bad.inspect} must be refused, not normalised") do
        resolve({ "TIME_ZONE" => bad })
      end
      assert_includes error.message, "TIME_ZONE #{bad.inspect}"
    end
  end

  test "outside production a bad TIME_ZONE warns and shows UTC, never the host's zone" do
    assert_equal "UTC", resolve({ "TIME_ZONE" => "Mars/Olympus", "TZ" => "Asia/Tokyo" }, rails_env: DEVELOPMENT)
    assert_equal 1, @logged.size
    assert_match(/TIME_ZONE "Mars\/Olympus" is not a time zone.*Showing times in UTC/, @logged.first)
  end

  test "unset or blank, it is the host's zone: TZ first" do
    [ {}, { "TIME_ZONE" => "" }, { "TIME_ZONE" => "  " } ].each do |env|
      assert_equal "Asia/Tokyo", resolve(env.merge("TZ" => "Asia/Tokyo"), localtime: localtime_to("/usr/share/zoneinfo/Europe/Berlin"))
      FileUtils.rm_f(@dir.join("localtime"))
    end
    assert_nil @logged, "an unset TIME_ZONE is not a mistake and says nothing"
  end

  test "then the zone /etc/localtime links to, on Debian's path and macOS's" do
    assert_equal "Europe/Berlin", resolve({ "TZ" => ":/etc/localtime" }, localtime: localtime_to("/usr/share/zoneinfo/Europe/Berlin"))
    FileUtils.rm_f(@dir.join("localtime"))
    assert_equal "America/New_York", resolve({}, localtime: localtime_to("/var/db/timezone/zoneinfo/America/New_York"))
    FileUtils.rm_f(@dir.join("localtime"))
    assert_equal "Etc/UTC", resolve({}, localtime: localtime_to("../usr/share/zoneinfo/Etc/UTC"))
  end

  test "then UTC: no link, a copied file, or a link that names no zone" do
    assert_equal "UTC", resolve({})
    copied = @dir.join("copied").tap { |p| p.write("TZif") }.to_s
    assert_equal "UTC", resolve({}, localtime: copied)
    assert_equal "UTC", resolve({}, localtime: localtime_to("/usr/share/zoneinfo/Not/AZone"))
  end

  test "the test env is UTC whatever TIME_ZONE or the host says, and a bad value still warns" do
    assert_equal "UTC", resolve({ "TIME_ZONE" => "Europe/Berlin", "TZ" => "Asia/Tokyo" }, rails_env: TEST,
                                localtime: localtime_to("/usr/share/zoneinfo/America/New_York"))
    assert_equal "UTC", resolve({ "TIME_ZONE" => "Mars/Olympus" }, rails_env: TEST)
    assert_equal 1, @logged.size
  end

  # The class body of config/application.rb is the one caller, and it runs before any test can
  # intercept it -- so the wiring is pinned by reading it, and the answer it gave by asking Rails.
  test "config/application.rb sets config.time_zone from it, and this suite runs in UTC" do
    source = Rails.root.join("config/application.rb").read
    assert_match(/^\s*config\.time_zone = Tinkerex::TimeZone\.resolve$/, source)
    assert_equal "UTC", Rails.application.config.time_zone
    assert_equal "UTC", Time.zone_default.name
  end
end
