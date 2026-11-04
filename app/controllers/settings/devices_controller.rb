# YOUR DESKTOP DEVICES AND ASSISTANTS (pentest H1b, tinkerex#465; docs/superpowers/plans/2026-10-22-device-token-lifecycle.md;
# assistants: docs/superpowers/specs/2026-11-04-mcp-server-design.md §6).
# Each row is one holder of a device token: a desktop app signed in to this account, or an AI
# assistant connected here. Signing one out deletes the row, which refuses that token at its next
# request. An admin does the same for another account on Settings → Users
# (Settings::UsersController#revoke_device).
#
# SESSION-AUTHED, NEVER THE DEVICE API (§14d). A stolen token must not be able to list the account's
# other devices, keep itself alive by signing the real one out, or mint a sibling for itself.
module Settings
  class DevicesController < ApplicationController
    # The name an assistant row gets when the form's field is left blank.
    DEFAULT_ASSISTANT_NAME = "AI assistant".freeze

    # Most recently used first, which is the order someone looking for a lost laptop reads in.
    # Sorted in Ruby on Device#last_active_at, the one definition of the idle clock.
    def index
      @devices = current_user.devices.to_a.sort_by(&:last_active_at).reverse
      @idle_limit = Device.idle_limit
    end

    # POST /settings/devices {device: {name}} -- CONNECT AN AI ASSISTANT. Mints a Device with NO sync
    # grant: an MCP client never syncs, and a dead sync server must not block connecting one
    # (V1::DevicesController's 503 rule is for devices that will sync). The token is RENDERED ONCE,
    # on this response, never through a redirect: a flash lives in the session cookie, and the
    # plaintext must not. The demo is refused before anything is minted, as both v1 doors refuse it.
    def create
      if Tinkerex::Demo.demo?(current_user)
        return redirect_to settings_devices_path, status: :see_other,
                           alert: "Refused: the shared demo account cannot connect an assistant."
      end

      name = params.fetch(:device, {}).permit(:name)[:name].to_s.strip.first(80).presence || DEFAULT_ASSISTANT_NAME
      @device = Device.register!(user: current_user, name: name)
      @token = @device.plaintext_token
      @mcp_url = "#{request.base_url}/mcp"
      render :connected
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
