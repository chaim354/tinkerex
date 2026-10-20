# Refuse to boot a deployment whose library backend is misconfigured, rather than surfacing it as
# a 500 on the first request. Mirrors lib/postgres_pooler_check.rb, which exists for the same
# reason: a misconfiguration that only shows up later is worse than one that stops the boot.
#
# The two backends get DIFFERENT DEPTHS of check, and the asymmetry is deliberate rather than an
# unfinished s3 leg:
#
#   share -> config presence AND a real filesystem probe. The mount is local, the probe is
#            microseconds, and File.writable? genuinely lies under the ACLs this backend targets
#            (see #writable!), so the filesystem is the only honest oracle available.
#   s3    -> config presence ONLY, NEVER the network. Boot must not depend on a third party being
#            reachable — that trades a clear config error for a crash loop on someone else's
#            outage. Reachability and credential validity surface on first use as FileLayer::
#            FetchError, which is retryable BY DESIGN. See #check_s3!.
#
# WHAT THIS DOES *NOT* CATCH, s3: a bucket that does not exist, credentials that are wrong or
# expired, a prefix that is empty or points at the wrong place, and an endpoint that is
# unreachable. ALL of them are boot-invisible by the decision above — every one is a first-use
# FetchError. The knobs being PRESENT is the whole of s3's boot claim; do not read it as more.
#
# WHAT THIS DOES *NOT* CATCH, share: an unmounted share. An unmounted mount point is a real, readable,
# writable, EMPTY directory — File.exist? and File.directory? both return true for it, and the
# write probe below SUCCEEDS on it (onto the underlying disk) — so no check here can distinguish
# "mounted" from "unmounted" (FileLayer::Share#library_present? uses emptiness as the signal at
# read time, where it belongs; an empty root is legitimate at boot, e.g. a brand-new library, so
# it must not stop the boot). This guard catches the configuration errors it actually can: a
# LIBRARY_PATH that is unset, typo'd, pointing at a file, unreadable, or not writable.
#
# ALSO NOT CAUGHT — a leaked probe, which is this guard's own contribution to the list above. The
# probe writes a file and unlinks it in an `ensure`, so every ordinary failure cleans up; a
# SIGKILL between the two does not, and the leaked dotfile then makes Share#library_present? read
# an unmounted share as mounted (emptiness is its signal), turning every retryable FetchError into
# a terminal NotFound until someone removes the file. That is the SAME known hole its header
# already names for a stale .DS_Store, not a new class, and it is a deliberate trade: probing
# nothing would swap a rare, self-inflicted false-mounted for a routine, silent read-only library
# that fails on the first upload instead of at boot. The probe is named with the Scanner's
# TEMP_PREFIX so a leak is at least never INDEXED (see #writable!).
module LibraryBackendCheck
  Error = Class.new(StandardError)

  # THE BACKENDS A DEPLOYMENT MAY NAME, AND THE ONE LIST OF THEM. FileLayer.build's `case` has one
  # arm per name and no other (factory_test.rb pins both directions). The retired embedded `chunk`
  # is absent on purpose: it is REFUSED, not aliased (CLAUDE.md §14a).
  NAMES = %w[share s3 chunk_remote].freeze

  # A LIBRARY_BACKEND that names no backend: a typo, a case or space variant, or a retired name. An
  # ArgumentError, the factory's long-standing answer to an unknown value -- and deliberately NOT an
  # Error: Library::RepoMetadataPurge rescues Error alone, to DECLINE where nothing is configured,
  # and an unknown value is a misconfigured DEPLOYMENT that must stay loud there.
  UnknownBackend = Class.new(ArgumentError)

  # Refused with the reason, so a retired name does not read as a typo. Not aliased: a deployment
  # still carrying `chunk` keeps its library on a sync server it was never pointed at, and serving
  # it some other backend would hand it an empty library that reads as data loss.
  RETIRED = {
    "chunk" => "the embedded sync engine, retired 2026-08-25 -- a library on a sync server is now " \
               "chunk_remote, which reaches it at CHUNK_REMOTE_URL"
  }.freeze

  # THE ONE READING OF LIBRARY_BACKEND, WITH THREE ANSWERS: nil when nothing is named (unset or
  # blank), the member of NAMES it names, or UnknownBackend. The boot (boot!) and the factory
  # (FileLayer.build) both consume it. They still ask it different questions -- the boot whether
  # this deployment may START, the factory which adapter to BUILD, and on nil the factory builds the
  # hermetic `share` while only production's boot refuses -- but neither derives the name itself.
  #
  # THE READERS IT REPLACED EACH NORMALISED DIFFERENTLY: the factory defaulted to `share`, check! to
  # the retired `chunk` (matching no arm, a "check nothing" sentinel), and the production guard took
  # anything non-blank -- so a typo passed both boot guards, and then every response 500'd, /up
  # included, from the CSP's connect_src lambda: the symptom 287ddac5 fixed for a blank value only.
  # (Tinkerex::Registration still reads the raw string for its own refusal. When it moves to this
  # answer, HAND it the name rather than call a raising reader from its own initializer: one typo,
  # one refusal.)
  #
  # REJECT, NEVER NORMALISE: " share" and "S3" are an operator's typo, and fixing them silently would
  # leave the deployment running on a guess nobody wrote down. Returns the member of NAMES itself,
  # never the raw string, so nothing downstream holds a value no check has seen.
  def self.configured(env: ENV)
    return nil if unset?(env)

    raw = env["LIBRARY_BACKEND"]
    name = NAMES.find { |known| known == raw }
    return name if name

    retired = " (#{RETIRED[raw]})" if RETIRED.key?(raw)
    raise UnknownBackend, "unknown LIBRARY_BACKEND #{raw.inspect}#{retired}: expected one of #{NAMES.join(' | ')}"
  end

  # Unset and blank are ONE state, defined once: an empty line in a .env or a compose variable that
  # expanded to nothing names no backend any more than a missing one does. `configured` and
  # required_in_production! both ask this, so the two cannot disagree about what "unset" means.
  def self.unset?(env) = env["LIBRARY_BACKEND"].to_s.strip.empty?
  private_class_method :unset?

  # THE BOOT'S QUESTION, AND config/initializers/library_backend_check.rb's ONLY CALL (pinned
  # statically by library_backend_required_test.rb: the test env skips that file). Each state gets
  # one answer. UNKNOWN refuses every boot -- `bin/rails db:prepare` in the entrypoint included --
  # rather than booting into a 500 on every response. NAMED runs that backend's own check!. NOTHING
  # NAMED is the one answer that depends on the environment: production refuses
  # (required_in_production!), development boots and the factory builds share. Do NOT make
  # development refuse it as well -- measured, that breaks an unconfigured dev box's `bin/setup` one
  # step EARLIER rather than fixing anything (§14a).
  def self.boot!(env: ENV, production: Rails.env.production?)
    name = configured(env:)
    return check!(env:, backend: name) if name

    required_in_production!(env:, production:)
  end

  # The knobs an s3 library cannot be built without. NOT LIBRARY_S3_REGION — it defaults to
  # "auto" (R2's value, matching Storage::S3ChunkStore's own default), and NOT LIBRARY_S3_ENDPOINT
  # or LIBRARY_S3_PREFIX, which are genuinely optional (endpoint = R2/SeaweedFS/MinIO; prefix = a
  # sub-root within the bucket, whose absence means "the whole bucket" and is a valid choice).
  S3_REQUIRED = %w[LIBRARY_S3_BUCKET LIBRARY_S3_ACCESS_KEY_ID LIBRARY_S3_SECRET_ACCESS_KEY].freeze
  # CHUNK_REMOTE_TOKEN WAS THE STAGE 4 DESIGN, AND THIS LIST ONCE OUTLIVED IT BY ONE ARC TOO MANY.
  # It used to be THE per-request device credential every user's traffic authenticated with — one
  # process-wide token, one shared sync-server identity for the whole deployment. Arc C (per-user
  # enrolment) replaced that: `users.sync_device_token` is now provisioned LAZILY, per user, the
  # first time each one actually touches their library (FileLayer::ChunkRemote::Provisioning),
  # authenticated against the sync server's admin door with SYNC_ADMIN_TOKEN — a single
  # deployment-wide OPERATOR credential, distinct from any device token, that the sync server
  # compares against its OWN copy of the same env var name (`authorize_admin` in
  # crates/tinkerex-sync/src/auth.rs on the far side). No runtime request-serving code reads
  # CHUNK_REMOTE_TOKEN any more (grep app/ and lib/: every remaining hit is a comment, this one
  # included).
  #
  # This list did not shrink when that landed, and it was wrong in BOTH directions at once: it
  # refused to boot without a device token nothing consumes, while SYNC_ADMIN_TOKEN — the one
  # credential a fresh deployment cannot provision ANY user's library without — went unchecked. The
  # practical result: a `remote` destination with no SYNC_ADMIN_TOKEN booted CLEANLY and then
  # FetchError'd the first time any user's first write reached Provisioning, which is a worse
  # failure than refusing to start (§14e: a config error surfacing later than boot is the thing this
  # whole module exists to prevent). The old argument for leaving SYNC_ADMIN_TOKEN out — "most
  # deployments never call that door" — does not hold for the case this guard actually protects: a
  # freshly stood-up chunk_remote deployment, where EVERY user starts with no sync_device_token and
  # auto-provisioning on first touch is the designed path, not an edge case. An operator who wants
  # to pre-seed every device by hand instead is still free to do so (Provisioning's fast path never
  # touches admin_transport once a token is already set) — they simply do not get a working
  # deployment with SYNC_ADMIN_TOKEN unset, which is the point.
  #
  # THE TWO REMAINING CHUNK_REMOTE_TOKEN REFERENCES (config/ci.rb's readiness probe, bin/sync-server)
  # ARE LOCAL DEV/CI HELPERS, NOT THIS APP'S OWN BOOT PATH — do not restore this constant on the
  # strength of finding it still grepped elsewhere. Both mint a real device against an EPHEMERAL
  # LOCAL sync server and prove that specific mint was accepted (`GET /v1/devices/whoami`); neither
  # asks "can a real deployment run," which is the only question this module answers. See each
  # file's own comment for why they keep it.
  #
  # SYNC_PUBLIC_URL (D1, 2026-10-13) IS THE SYNC SERVER'S ADDRESS AS DEVICES REACH IT, AND IT IS NOT
  # CHUNK_REMOTE_URL. A desktop app signs in to THIS app and is handed a sync grant whose URL is this
  # value; CHUNK_REMOTE_URL is where THIS PROCESS dials the same server. On one box they differ on
  # purpose: the app's address is a name only its own container network resolves (Kamal's
  # http://tinkerex-sync:3000, compose's http://sync:3000), and no device is on that network -- they
  # come in through a proxied host name or a published port. Neither is derivable from the other, so
  # both are configured. Required at boot for the reason SYNC_ADMIN_TOKEN is: unset, the deployment
  # boots cleanly and then every desktop sign-in fails. PRESENCE ONLY, like everything here, and for
  # this knob not merely by policy -- the devices' address need not even resolve from inside the
  # container (split DNS, a front proxy on another host), so no probe from this process could tell a
  # good value from a bad one.
  CHUNK_REMOTE_REQUIRED = %w[CHUNK_REMOTE_URL SYNC_ADMIN_TOKEN SYNC_PUBLIC_URL].freeze

  # One backend's own configuration, for a NAME its caller already resolved: boot! passes what
  # `configured` read, and each of FileLayer.build's arms passes its own -- the factory calls this
  # too, so a bad configuration gets this explanation even when the boot guard did not run (the
  # test env) or when ENV changed after boot.
  #
  # `backend:` HAS NO DEFAULT, AND THAT IS THE FIX. It defaulted to env.fetch("LIBRARY_BACKEND",
  # "chunk") until 2026-10-19 -- the retired name, matching no arm, as a "check nothing" sentinel --
  # and that private default had already drifted from the factory's once (§14a: the one backend
  # reachable without setting LIBRARY_BACKEND was the one the guard never checked).
  #
  # ONE injection seam for configuration: `env`. This used to be `check!(backend:, path:)`, and
  # phase 3 could have bolted an `env:` beside it for s3's five knobs — but `path:` was only ever
  # env["LIBRARY_PATH"] spelled differently, and two ways to inject config into one method is how
  # the third backend invents a third way.
  #
  # A hybrid was considered and is a TRAP, recorded so it is not "restored": `path: nil` cannot
  # mean both "unset" and "not passed". The existing share tests pass `path: nil` and expect a
  # raise, but the share CI leg runs with LIBRARY_PATH set — so a `path:` defaulting to
  # env["LIBRARY_PATH"] would silently read the ambient value and those tests would stop testing.
  def self.check!(backend:, env: ENV)
    case backend
    when "share" then check_share!(env["LIBRARY_PATH"])
    when "s3"    then check_s3!(env)
    when "chunk_remote" then check_chunk_remote!(env)
    end
    # No `else`: both callers pass a name `configured` has already validated, and an unknown value
    # is refused THERE, once, with one message.
  end

  # PRODUCTION REFUSES TO BOOT WITH NO BACKEND NAMED -- boot!'s answer for the nothing-named state.
  # Development boots on it and the factory builds share (§14a); in production the same gap used to
  # boot cleanly and then 500 on EVERY request, /up included, because the CSP header's connect_src
  # lambda resolves FileLayer.current per response and the raise happens in middleware. Exempt: the
  # image build's assets:precompile, which Rails marks with SECRET_KEY_BASE_DUMMY and which boots
  # production with nothing set. An UNKNOWN value is not this method's to judge: boot! asks
  # `configured` first, which refuses it in every environment.
  def self.required_in_production!(env: ENV, production: Rails.env.production?)
    return nil unless production
    return nil if env["SECRET_KEY_BASE_DUMMY"].present?
    return nil unless unset?(env)

    raise Error, "LIBRARY_BACKEND is not set (#{NAMES.join(' | ')}). A production deployment " \
                 "must name its library backend; without one every request, /up included, answers 500."
  end

  # Config PRESENCE only — this must never reach the network, and that is a design decision rather
  # than an omission. The share leg touch-probes because File.writable? genuinely lies under the
  # NFS/SMB ACLs it targets, so the filesystem is the only honest oracle. S3 is different in kind:
  # a live round-trip at boot would make our process's ability to START depend on a third party
  # being reachable, turning a transient blip — or a bucket that is merely slow this second — into
  # a crash loop, right when an operator most needs the app up to look at it. Credential and
  # reachability errors surface on first USE as FetchError, which is retryable BY DESIGN (see
  # FileLayer::FetchError). Presence is what boot can honestly check; validity is not.
  # CONFIG PRESENCE ONLY, AND NO NETWORK -- the same rule §14a states for the S3 guard, for the same
  # reason: a boot that depends on a third party being reachable turns a blip into a crash loop. That
  # the sync server is down is exactly the condition chunk_remote is built to survive (reads answer
  # from the local mirror), so refusing to boot for it would defeat the design.
  def self.check_chunk_remote!(env)
    missing = CHUNK_REMOTE_REQUIRED.reject { |knob| env[knob].present? }
    return if missing.empty?

    # The list comes first and ends at the dash; everything after it explains all three knobs
    # whichever are missing, so a test asserts on the list (library_backend_check_test.rb).
    raise Error, "LIBRARY_BACKEND=chunk_remote requires #{missing.join(', ')} — " \
                 "CHUNK_REMOTE_URL is the sync server's address as THIS APP dials it, and " \
                 "SYNC_PUBLIC_URL is the same server's address as DEVICES reach it: a desktop app " \
                 "that signs in here is handed it in the login answer. They are different addresses " \
                 "on purpose -- on one box the app dials a name only its own container network " \
                 "resolves (http://sync:3000 under compose, http://tinkerex-sync:3000 under Kamal), " \
                 "while devices come in through the published port or a proxied host name -- so " \
                 "neither can stand in for the other. SYNC_ADMIN_TOKEN is the operator credential " \
                 "this deployment auto-provisions every new user's library with " \
                 "(FileLayer::ChunkRemote::Provisioning calls POST /v1/admin/libraries on that " \
                 "server with it); without it this deployment cannot provision a library for ANY " \
                 "user -- it must be the SAME value the sync server's own SYNC_ADMIN_TOKEN carries, " \
                 "or every provisioning attempt gets refused as an unrecognised credential (a " \
                 "mismatch is not caught here, only on a user's first write, as a FetchError)."
  end

  def self.check_s3!(env)
    # blank?, not key? — "" and "   " are the same operator error as unset (an empty line in a
    # .env, a shell variable that expanded to nothing), and calling them configured just hands
    # the SDK a blank bucket to fail on later, naming none of our knobs.
    missing = S3_REQUIRED.reject { |knob| env[knob].present? }
    return if missing.empty?

    # ALL of them, in one message. A guard that reveals one missing knob per restart makes the
    # operator do N boots to learn N facts we already know here.
    raise Error, "LIBRARY_BACKEND=s3 requires #{missing.join(', ')} — set " \
                 "#{'it' if missing.one?}#{'them' unless missing.one?} to the bucket and " \
                 "credentials for the S3-compatible storage holding the library. Optional: " \
                 "LIBRARY_S3_REGION (default \"auto\"), LIBRARY_S3_ENDPOINT (set for " \
                 "R2/SeaweedFS/MinIO), LIBRARY_S3_PREFIX (the library's root in the bucket)."
  end

  def self.check_share!(path)
    raise Error, "LIBRARY_BACKEND=share requires LIBRARY_PATH (the mounted directory to index)" if path.blank?
    unless File.exist?(path)
      # THE COMMON CASE IS A CONTAINER WITH NOTHING MOUNTED AT /library (I, 2026-10-14): the image
      # defaults LIBRARY_PATH to /library, so a bare `docker run` with no -v lands here. It must keep
      # REFUSING -- an unmounted /library inside the container would take uploads into the container's
      # own filesystem, which reads as data loss on the next recreate -- and say how the mount is made.
      raise Error, "LIBRARY_PATH #{path.inspect} does not exist — the library folder is not mounted " \
                   "there. With the compose file, LIBRARY_HOST_PATH in .env names the folder bound " \
                   "to /library (default: the compose file's own folder); with docker run, " \
                   "-v /path/to/your/files:/library. Outside a container, check the path is spelled " \
                   "correctly and that the mount point has been created"
    end
    raise Error, "LIBRARY_PATH #{path.inspect} is not a directory" unless File.directory?(path)
    raise Error, "LIBRARY_PATH #{path.inspect} is not readable" unless File.readable?(path)
    # LAST, and the order is the operator's error message: a missing root must say "does not
    # exist", not "is not writable". Every check above answers a question this one cannot even
    # ask — you cannot meaningfully probe a path that is a file, or one that isn't there.
    writable!(path)
  end

  # A REAL write, not File.writable?. File.writable? tests POSIX mode bits against the process
  # uid/gid — it does not consult NFSv4/SMB ACLs, an SMB share's read-only export flag, or a
  # remount-ro, and every one of those is a live possibility for the mounted directory this
  # backend exists to serve. On those it cheerfully answers true for a root we cannot write, and
  # the operator learns the truth from a failed upload instead of a refused boot. The only honest
  # question is "can we create a file here?", so ask it.
  #
  # NOTE for whoever revisits this: no unit test can tell the two implementations apart, because
  # only an ACL-bearing filesystem can — substituting `File.writable?` here keeps the whole suite
  # green. The touch-probe is justified by the DEPLOYMENT TARGET, not by a red test. Do not
  # "simplify" it back on the evidence of the tests.
  #
  # Named with the Scanner's TEMP_PREFIX (which it skips at every depth) rather than a prefix of
  # this file's own invention, and the reason is a wedge rather than tidiness: the Scanner walks
  # this root every 15 minutes, a boot can land inside a scan, and a probe it INDEXED would vanish
  # on unlink — an observation that can never pair, whose tombstone trips the mass-deletion guard
  # and refuses that scan and every scan after it. Share#write reuses the same constant for the
  # same reason; see Library::Scanner::TEMP_PREFIX, which documents the reproduction. The random
  # suffix means two boots (or a boot racing a purge) cannot collide on the name.
  #
  # That reference has a REAL COST, and it is paid at the call site: this is lib/ reaching into
  # app/, and app/ constants are not autoloadable while initializers run — calling this from an
  # initializer's top level raises `uninitialized constant Library` and takes the boot down for
  # the wrong reason (observed, not theorized). config/initializers/library_backend_check.rb
  # therefore calls check! from after_initialize. Any NEW caller earlier than that must either do
  # the same or not call this method.
  def self.writable!(path)
    probe = File.join(path, "#{Library::Scanner::TEMP_PREFIX}probe-#{Process.pid}-#{SecureRandom.hex(4)}")
    begin
      File.binwrite(probe, "")
    rescue SystemCallError => e
      raise Error, "LIBRARY_PATH #{path.inspect} is not writable (#{e.class}: #{e.message}) — " \
                   "phase 2b writes uploads and moves deletes into .trash/, so a read-only " \
                   "share cannot back a library. Check the mount options and the export's " \
                   "permissions for the user this process runs as."
    ensure
      # MUST NOT leak — see the header. Share#library_present? reads "the root is empty" as
      # "unmounted", so a stale probe would make an unmounted share look mounted and flip every
      # transient ENOENT to a terminal NotFound.
      begin
        File.unlink(probe)
      rescue SystemCallError
        nil
      end
    end
  end
end
