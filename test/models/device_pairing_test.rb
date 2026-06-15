require "test_helper"

class DevicePairingTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "pair@example.com") }

  test "issue! produces an 8-char code from the unambiguous alphabet" do
    rec = DevicePairing.issue!(user: @user)
    code = rec.plaintext_code
    assert_equal 8, code.length
    assert code.chars.all? { |c| DevicePairing::ALPHABET.include?(c) },
           "code uses only the unambiguous alphabet"
    # Only the digest is persisted; plaintext is shown once.
    assert_equal DevicePairing.digest(code), rec.code_digest
  end

  test "issue! codes are unique across many draws (CSPRNG, not a constant)" do
    codes = Array.new(50) { DevicePairing.issue!(user: @user).plaintext_code }
    assert_equal codes.uniq.length, codes.length, "no collisions across 50 fresh codes"
  end

  test "claim! succeeds once then fails (single-use)" do
    rec = DevicePairing.issue!(user: @user)
    code = rec.plaintext_code
    assert DevicePairing.claim!(user: @user, code: code)
    assert_not DevicePairing.claim!(user: @user, code: code), "a code is single-use"
  end
end
