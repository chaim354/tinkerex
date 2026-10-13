module Tinkerex
  # Active Record encryption keys from the ENVIRONMENT, for a deployment that has no master key.
  # Rails reads these only from credentials; this app's credentials.yml.enc is committed and baked
  # into the image, and only the author holds its key. A value set on
  # config.active_record.encryption in an initializer is splatted over the credential by the
  # railtie, so present ENV values win and absent ones leave the credential alone — ONLY WHEN
  # PRESENT is load-bearing: a nil would win too and break every credentials-based deployment.
  module EncryptionKeys
    NAMES = %w[primary_key deterministic_key key_derivation_salt].freeze

    def self.from_env(env = ENV)
      NAMES.each_with_object({}) do |name, keys|
        value = env["ACTIVE_RECORD_ENCRYPTION_#{name.upcase}"].to_s
        keys[name.to_sym] = value if value.present?
      end
    end
  end
end
