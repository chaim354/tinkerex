require "securerandom"
require "fileutils"

module Tinkerex
  # THE SESSION SECRET, GENERATED ON FIRST BOOT AND KEPT IN THE VOLUME (I, 2026-10-14). Rails refuses
  # to boot in production without a secret_key_base, and a stranger's image has no master key for
  # the committed credentials, so until now every install began with `openssl rand -hex 64` pasted
  # into .env. The order now: SECRET_KEY_BASE from the environment -- a BLANK counts as unset, because
  # .env.example shipped `SECRET_KEY_BASE=` as a line to fill in and an old .env may still carry it --
  # else the credential (the author's deployments, which hold the master key), else a file in
  # storage/, read if present and generated once if not. storage/ is the persistent volume, beside
  # production.sqlite3: whoever holds the volume holds the database already, and restoring the
  # volume restores sessions with it.
  #
  # production.rb assigns the result to config.secret_key_base, whose setter takes any non-blank
  # String; Devise derives its own key from it. SKIPPED under SECRET_KEY_BASE_DUMMY, the image
  # build's assets:precompile: Rails generates a throwaway there, and a secret written during the
  # build would bake into the image layer.
  #
  # Failure is loud. A storage directory that cannot be written raises with the path and the
  # override, never a per-boot random value that would sign everyone out on every restart.
  module SecretKeyBase
    Error = Class.new(StandardError)
    FILE = "secret_key_base".freeze

    def self.resolve(dir:, env: ENV, credential: nil, log: ->(msg) { warn(msg) })
      return nil if env["SECRET_KEY_BASE_DUMMY"].present?

      from_env = env["SECRET_KEY_BASE"].to_s.strip
      return from_env if from_env.present?
      return credential if credential.to_s.strip.present?

      from_file(File.join(dir.to_s, FILE), log:)
    end

    def self.from_file(path, log:)
      existing = File.read(path).strip if File.file?(path)
      return existing if existing.present?

      secret = SecureRandom.hex(64)
      write_atomically(path, secret)
      log.call("Generated a session secret and kept it at #{path}. Set SECRET_KEY_BASE to use your own instead.")
      secret
    rescue SystemCallError => e
      raise Error, "cannot read or create the session secret at #{path} (#{e.class}: #{e.message}). " \
                   "The storage volume must be writable by the user the app runs as (PUID), or set " \
                   "SECRET_KEY_BASE in the environment."
    end

    # Temp-then-rename so a crash mid-write never leaves a half-written secret to be read as the
    # whole one; EXCL + 0600 so the file is never readable by anyone else, even for an instant.
    def self.write_atomically(path, secret)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(secret) }
      File.rename(tmp, path)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end
    private_class_method :write_atomically
  end
end
