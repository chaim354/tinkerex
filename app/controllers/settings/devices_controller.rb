# YOUR DESKTOP DEVICES (pentest H1b, tinkerex#465; docs/superpowers/plans/2026-10-22-device-token-lifecycle.md).
# Each row is a desktop app signed in to this account with a token of its own (Device). Signing one
# out deletes the row, which refuses that token at its next request. An admin does the same for
# another account on Settings → Users (Settings::UsersController#revoke_device).
#
# SESSION-AUTHED, NEVER THE DEVICE API (§14d). A stolen token must not be able to list the account's
# other devices, or keep itself alive by signing the real one out.
module Settings
  class DevicesController < ApplicationController
    # Most recently used first, which is the order someone looking for a lost laptop reads in.
    # Sorted in Ruby on Device#last_active_at, the one definition of the idle clock.
    def index
      @devices = current_user.devices.to_a.sort_by(&:last_active_at).reverse
      @idle_limit = Device.idle_limit
    end

    # SCOPED THROUGH current_user, NEVER Device.find: a foreign id must 404, not sign out someone
    # else's laptop (Settings::TagsController#destroy makes the same argument).
    def destroy
      device = current_user.devices.find(params[:id])
      device.destroy!
      redirect_to settings_devices_path, status: :see_other,
                  notice: "Signed out #{device.name}. It needs your password to sign in again."
    end
  end
end
