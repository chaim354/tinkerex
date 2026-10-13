require "test_helper"

# A stranger runs with SECRET_KEY_BASE and three ACTIVE_RECORD_ENCRYPTION_* variables and NO master
# key; the author's deployments keep their credentials. The function returns only the keys that
# are PRESENT: assigning nil would be splatted over the credential value by the railtie and break
# every credentials-based deployment (the design records why).
class EncryptionKeysTest < ActiveSupport::TestCase
  test "nothing when nothing is set" do
    assert_equal({}, Tinkerex::EncryptionKeys.from_env({}))
    assert_equal({}, Tinkerex::EncryptionKeys.from_env({ "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "" }))
  end

  test "each present key, under the name config.active_record.encryption takes" do
    env = { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "p" * 32,
            "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "d" * 32,
            "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "s" * 32 }
    assert_equal({ primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32 },
                 Tinkerex::EncryptionKeys.from_env(env))
  end

  test "a partial set is passed through partially — the missing one still comes from credentials" do
    assert_equal({ primary_key: "p" * 32 },
                 Tinkerex::EncryptionKeys.from_env({ "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "p" * 32 }))
  end
end
