require "test_helper"

# REGISTRATION is closed by default in production and open in development and test; `open` is
# refused on the single-library backends, where every account indexes the same files.
class RegistrationTest < ActiveSupport::TestCase
  test "the default mode is closed in production and open elsewhere" do
    assert_equal "closed", Tinkerex::Registration.mode({}, production: true)
    assert_equal "open",   Tinkerex::Registration.mode({}, production: false)
    assert_equal "open",   Tinkerex::Registration.mode({ "REGISTRATION" => "open" }, production: true)
  end

  test "validate! refuses an unknown mode and refuses open on share and s3" do
    assert_raises(Tinkerex::Registration::Error) { Tinkerex::Registration.validate!({ "REGISTRATION" => "maybe" }) }
    %w[share s3].each do |backend|
      e = assert_raises(Tinkerex::Registration::Error) do
        Tinkerex::Registration.validate!({ "REGISTRATION" => "open", "LIBRARY_BACKEND" => backend })
      end
      assert_match(/same library/, e.message)
    end
    assert_nil Tinkerex::Registration.validate!({ "REGISTRATION" => "open", "LIBRARY_BACKEND" => "chunk_remote" })
    assert_nil Tinkerex::Registration.validate!({ "REGISTRATION" => "closed", "LIBRARY_BACKEND" => "share" })
  end

  test "the state a visitor is in" do
    r = Tinkerex::Registration
    assert_equal :first_owner,  r.state(mode: "closed", users_exist: false, mail_configured: false)
    assert_equal :closed,       r.state(mode: "closed", users_exist: true,  mail_configured: true)
    assert_equal :open,         r.state(mode: "open",   users_exist: true,  mail_configured: true)
    assert_equal :open_no_mail, r.state(mode: "open",   users_exist: true,  mail_configured: false)
    assert_equal :first_owner,  r.state(mode: "open",   users_exist: false, mail_configured: false),
                 "the very first account never needs mail, whatever the mode"
  end

  # The refusal is of an OPERATOR'S explicit `open`, never of the non-production default. bin/ci's
  # share and s3 legs boot DEVELOPMENT first (`db:test:prepare`, config/ci.rb) with LIBRARY_BACKEND
  # exported, and the dev server runs share: a refusal keyed on the resolved mode would refuse every
  # one of those boots, since the default outside production is open. Production's default is
  # closed, so an unset value never reaches the branch there.
  test "the non-production default is not an operator's choice and does not refuse a share boot" do
    assert_equal "open", Tinkerex::Registration.mode({ "LIBRARY_BACKEND" => "share" }, production: false)
    assert_nil Tinkerex::Registration.validate!({ "LIBRARY_BACKEND" => "share" }, production: false)
    assert_nil Tinkerex::Registration.validate!({ "LIBRARY_BACKEND" => "s3" }, production: false)
  end
end
