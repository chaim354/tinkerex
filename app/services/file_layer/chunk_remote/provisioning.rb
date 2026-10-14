# frozen_string_literal: true

module FileLayer
  class ChunkRemote
    # LAZILY PROVISIONS A REMOTE LIBRARY FOR A MAKER USER WHO HAS NEVER HAD ONE — Arc C Task 5,
    # and the other half of the per-user fix Task 4 makes possible. Before this arc, every maker
    # user reached the sync server as the SAME single bootstrap device (one process-wide
    # CHUNK_REMOTE_TOKEN), so two maker users shared one remote library and could see each other's
    # files. Task 4 gives every user their OWN column (`users.sync_device_token`); this class is
    # what FILLS it in, the first time a user actually touches their library, by calling the sync
    # server's `POST /v1/admin/libraries` (chaim354/tinkerex-sync,
    # app/controllers/sync/v1/admin/libraries_controller.rb) — read directly, not assumed, because
    # the exact refusal shapes below (409 email_taken, 503 admin_provisioning_disabled) are that
    # controller's own documented behaviour, not this file's guess at it.
    #
    # EXACTLY ONCE PER USER, UNDER CONCURRENCY. `user.with_lock` is the SAME primitive
    # `User#next_seq!` already relies on for exactly this shape (app/models/user.rb's own
    # comment): `SELECT ... FOR UPDATE` on Postgres, and on SQLite a transaction that — because
    # this app's sqlite3 adapter defaults to `default_transaction_mode: :immediate` (verified
    # against activerecord 8.1.3.1's sqlite3_adapter.rb) — grabs SQLite's one global write lock at
    # BEGIN, not lazily at the first write. Either way, a SECOND thread's `with_lock` call for the
    # SAME user BLOCKS until the first's transaction commits, then re-reads `sync_device_token`
    # inside the lock and finds it already set — so the second caller never dials the admin
    # endpoint at all. Proved with two real threads and a deliberately slow fake admin transport in
    # provisioning_test.rb, not merely argued.
    #
    # HOLDING THAT LOCK ACROSS THE ADMIN HTTP CALL IS DELIBERATE, NOT AN OVERSIGHT LEFT FOR LATER.
    # It only ever contends against a SECOND request for the SAME not-yet-provisioned user — every
    # other user's row is untouched — and it happens AT MOST ONCE per user, ever: every later call
    # sees a token already present and returns before touching the lock at all (the guard at the
    # top of #call). On Postgres (the only deployment shape with more than one maker user, §7) that
    # is one row's contention, self-resolving the moment the winner's request finishes. On SQLite
    # (self-host, §8: tenant = user) there is no second user to contend with in the first place.
    #
    # `admin_transport:` IS INJECTABLE for the same reason ChunkRemote's own `transport:`/
    # `chunk_fetch:` seams are (chunk_remote.rb): a test that cannot substitute the wire can only
    # exercise this against a real sync server.
    class Provisioning
      def initialize(admin_transport: nil)
        @admin_transport = admin_transport
      end

      # Returns this user's device token, provisioning a fresh remote library first if this is
      # their first library use. Safe to call unconditionally and often — the fast path (a token
      # already present) touches neither the lock nor the network.
      def call(user)
        return user.sync_device_token if user.sync_device_token.present?

        user.with_lock do
          if user.sync_device_token.blank?
            minted = provision_remote!(user)
            # update_column, matching User#next_seq! two doors down: no validations/callbacks to
            # run for a column nothing else derives from, and — the part that matters here — it
            # goes through the SAME attribute-type machinery a plain assignment would, so
            # `encrypts :sync_device_token` still encrypts what lands in the column. update_all
            # would NOT: it writes raw SQL from the hash it is given, bypassing the attribute type
            # system (and the encryption it implements) entirely — the one difference that makes
            # update_all unsafe for an encrypted column and update_column safe.
            user.update_column(:sync_device_token, minted)
          end
        end

        user.sync_device_token
      rescue FileLayer::UnsupportedOperation => e
        # THE ADMIN ENDPOINT'S 409 EMAIL_TAKEN, AND ITS OWN RARER SIBLINGS. Transport#interpret maps
        # 409/422/501 to this one class for every chunk_remote call, so this catches THE ONLY
        # UnsupportedOperation this method's own call graph can raise: the admin endpoint refusing
        # to mint a device for an email it already has a User for. That happens the ORDINARY way
        # (the controller's own `User.exists?(email:)` check, 409 `email_taken`) and, rarely, the
        # RACE way (two admin calls for the same email that both slipped past that check — the
        # controller's own comment says the loser hits either `ActiveRecord::RecordInvalid`, 422,
        # or `RecordNotUnique`, 409) — deliberately NOT distinguished here: both mean the same thing
        # to THIS caller, "this email is already claimed remotely and I did not get a token for
        # it," and Task 5's own lock above is what keeps the race arm vanishingly rare in the first
        # place (two THIS APP's requests for the same user cannot both reach the network at once;
        # only a second, uncoordinated caller — a stale instance, a different deployment — could
        # still hit it).
        #
        # DECIDED: this becomes FileLayer::FetchError, not FileLayer::NotFound and not left as
        # UnsupportedOperation. The library is NOT gone (NotFound would be a lie about a file that
        # exists). UnsupportedOperation was considered and is at least as defensible on the
        # "retrying THIS request never helps" axis — but FetchError's own existing message is
        # already generic "couldn't reach your library, try again" filler for causes that differ
        # WIDELY in whether trying again helps (a full NAS, an expired credential, this) — so a
        # provisioning conflict that needs an operator is not a NEW category of imprecision this
        # class introduces, only another member of one FileLayer::FetchError already tolerates. It
        # also means every existing FileLayer caller's `rescue_from FileLayer::FetchError`
        # (FilesController, TrashController, ModelsController, Projects::UploadsController,
        # Tools::AddonsController) renders this correctly with no new wiring. The message here is
        # written for whoever reads logs, not the flash banner, and says plainly that automatic
        # retry will not fix it — recovery is an operator reissuing a device by hand (e.g.
        # `tinkerex-sync device issue` in the sync container) and setting `users.sync_device_token`.
        raise FileLayer::FetchError,
              "cannot auto-provision a library for #{user.email.inspect}: the sync server " \
              "refused (#{e.message}) -- most likely it already has one and this app has no " \
              "local device token for it; automatic retry will not fix this, an operator must " \
              "reissue a device by hand and set users.sync_device_token"
      end

      private

      def provision_remote!(user)
        body = admin_transport.post("/v1/admin/libraries", { email: user.email })
        # .fetch, NOT body["device_token"] -- unlike finalize_upload's soft `body["version_id"]`
        # (whose caller already tolerates a nil via `node ? ... : nil`), a 2xx admin response with
        # no device_token is a CONTRACT VIOLATION between this app and the sync server, not a
        # routine condition to paper over. Silently writing a nil token would look "provisioned"
        # while leaving the user unable to sync, discovered only much later. Raising loudly here
        # (an uncaught KeyError, matching how NotImplementedError is deliberately left unrescued
        # for a wiring bug elsewhere in this file) is the honest answer for a bug, not a 503.
        body.fetch("device_token")
      end

      # Built lazily, from SYNC_ADMIN_TOKEN -- NOT CHUNK_REMOTE_TOKEN. The two are different
      # credentials for different doors: CHUNK_REMOTE_TOKEN is a DEVICE token, and the admin
      # endpoint structurally cannot accept one (`authorize_admin` in chaim354/tinkerex-sync's
      # crates/tinkerex-sync/src/auth.rs compares the bearer against SYNC_ADMIN_TOKEN and nothing
      # else — a device token presented there is not "checked and rejected", it is simply not a
      # credential that path reads; until Phase 6 the Ruby engine's admin controller kept the same
      # rule by never inheriting its device-authenticating base). Reads CHUNK_REMOTE_URL because the
      # admin endpoint lives on the same sync server every per-user request already talks to —
      # there is no separate "admin host" to configure.
      #
      # UNSET IS A FetchError, NOT A KeyError -- an operator who has not configured auto-
      # provisioning yet (every existing single-user self-host deployment, today) must see the same
      # retryable, named condition Transport itself raises for a rejected credential, not a bare
      # stack trace the first time some user's first library write reaches this path.
      def admin_transport
        @admin_transport ||= Transport.new(
          base_url: ENV.fetch("CHUNK_REMOTE_URL"),
          token: ENV.fetch("SYNC_ADMIN_TOKEN") {
            raise FileLayer::FetchError,
                  "cannot auto-provision a library: SYNC_ADMIN_TOKEN is not set on this " \
                  "deployment -- either set it (matching the sync server's own SYNC_ADMIN_TOKEN) " \
                  "or provision this user's device by hand with `tinkerex-sync device issue` in " \
                  "the sync container and set users.sync_device_token"
          }
        )
      end
    end
  end
end
