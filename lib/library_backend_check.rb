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
  # compares against its OWN copy of the same env var name (Sync::V1::Admin::
  # LibrariesController#authenticate_admin! on the far side). No runtime request-serving code reads
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
  CHUNK_REMOTE_REQUIRED = %w[CHUNK_REMOTE_URL SYNC_ADMIN_TOKEN].freeze

  # Reads the same ENV vars, with the same defaults, as FileLayer.build — the factory calls this
  # too, so a bad configuration gets this explanation even when the boot guard did not run (the
  # test env) or when ENV changed after boot.
  #
  # ONE injection seam: `env`. This used to be `check!(backend:, path:)`, and phase 3 could have
  # bolted an `env:` beside it for s3's five knobs — but `path:` was only ever env["LIBRARY_PATH"]
  # spelled differently, and two ways to inject config into one method is how the third backend
  # invents a third way. `backend:` defaults out of the same Hash (kwarg defaults evaluate left to
  # right, so `env` is bound by the time it is read), which also retires a second, separate read
  # of the real ENV.
  #
  # A hybrid was considered and is a TRAP, recorded so it is not "restored": `path: nil` cannot
  # mean both "unset" and "not passed". The existing share tests pass `path: nil` and expect a
  # raise, but the share CI leg runs with LIBRARY_PATH set — so a `path:` defaulting to
  # env["LIBRARY_PATH"] would silently read the ambient value and those tests would stop testing.
  def self.check!(env: ENV, backend: env.fetch("LIBRARY_BACKEND", "chunk"))
    case backend
    when "share" then check_share!(env["LIBRARY_PATH"])
    when "s3"    then check_s3!(env)
    when "chunk_remote" then check_chunk_remote!(env)
    end
    # No `else`: an unknown backend is FileLayer.build's ArgumentError to raise, not this guard's.
    # Duplicating it here would give the operator two different messages for one typo.
  end

  # PRODUCTION REFUSES TO BOOT WITH NO BACKEND NAMED. check!'s own default (`chunk`, deliberately
  # NOT the factory's `share` — §14a) lets an unconfigured development box boot; in production the
  # same gap used to boot cleanly and then 500 on EVERY request, /up included, because the CSP
  # header's connect_src lambda resolves FileLayer.current per response and the raise happens in
  # middleware. Exempt: the image build's assets:precompile, which Rails marks with
  # SECRET_KEY_BASE_DUMMY and which boots production with nothing set.
  def self.required_in_production!(env: ENV, production: Rails.env.production?)
    return nil unless production
    return nil if env["SECRET_KEY_BASE_DUMMY"].present?
    return nil if env["LIBRARY_BACKEND"].to_s.strip.present?

    raise Error, "LIBRARY_BACKEND is not set (share | s3 | chunk_remote). A production deployment " \
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

    raise Error, "LIBRARY_BACKEND=chunk_remote requires #{missing.join(', ')} — the sync server " \
                 "this app syncs against, and the operator credential this deployment auto-" \
                 "provisions every new user's library with (FileLayer::ChunkRemote::Provisioning " \
                 "calls POST /v1/admin/libraries on that server with it). Without SYNC_ADMIN_TOKEN " \
                 "this deployment cannot provision a library for ANY user -- it must be the SAME " \
                 "value the sync server's own SYNC_ADMIN_TOKEN carries, or every provisioning " \
                 "attempt gets refused as an unrecognised credential (a mismatch is not caught " \
                 "here, only on a user's first write, as a FetchError)."
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
      raise Error, "LIBRARY_PATH #{path.inspect} does not exist — check the path is spelled " \
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
