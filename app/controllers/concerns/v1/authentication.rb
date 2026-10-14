# frozen_string_literal: true

# BEARER DEVICE-TOKEN AUTH FOR THE HOST'S OWN v1 API — the fourteen v1/maker/* controllers plus
# devices and test_users.
#
# THIS IS A SECOND COPY OF THE SYNC SERVER'S DEVICE AUTH (chaim354/tinkerex-sync's
# crates/tinkerex-sync/src/auth.rs `authenticate`; the Ruby engine's Sync::V1::Authentication until
# Phase 6 deleted it on 2026-10-14), AND THE DUPLICATION IS STRUCTURAL RATHER THAN LAZY. Since Arc D
# Part 2 the sync server is not a dependency of this app on ANY backend — `Sync::` is undefined in
# this process (CLAUDE.md §12.12, §14j) — and since Phase 6 it is not even Ruby, so neither side can
# include the other's code. A shared third home would have to be a library BOTH repos depend on, for
# twelve lines whose only real dependency is a `Device` model each side already owns over its own
# `devices` table (§14j: Device stays host-side precisely because its token is the only credential
# this app's v1 API accepts).
#
# NOTHING CHECKS THAT THE TWO COPIES STILL AGREE, AND NOTHING HAS SINCE 2026-08-24. There WAS a
# parity test comparing the two method bodies while the engine shared this process; it went with
# the extraction (deleted in eaa180b) and was never replaced. So did the byte-identical cross-repo
# schema guard this comment used to cite as the same shape (448ba3b, f4e5172 — see the Gemfile's
# own note, which already lists that generator among what Arc D Part 2 removed). §14j records the
# obligation as unguarded in as many words: IF YOU CHANGE DEVICE-TOKEN VERIFICATION HERE, CHANGE
# IT IN tinkerex-sync IN THE SAME BREATH. That repo's copy carries no counterpart note, so this is
# the only place either side says so. (Checked 2026-08-26: the two Ruby `authenticate_device!`
# bodies were identical modulo indentation and one blank line. Read against the Rust 2026-10-14:
# the same steps — strip an optional `Bearer `, trim, refuse a blank token, look the SHA256 digest
# up in `devices.token_digest`, stamp `last_seen_at`.)
module V1
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_device!
    end

    private

    def authenticate_device!
      token = request.authorization.to_s.delete_prefix("Bearer ").strip
      @current_device = Device.authenticate(token)
      return render(json: { error: "unauthorized" }, status: :unauthorized) unless @current_device

      @current_user = @current_device.user
      @current_device.touch_seen!
    end

    def current_user = @current_user
    def current_device = @current_device
  end
end
