# The settings hub (stage 2, S2-6; the Library row added in K, the admins-only Users row on
# 2026-10-21, the Devices row on 2026-10-22, the Version stacks row on 2026-11-24). One door onto the
# library folder, the reference pages, the accounts, the account page, its devices, the theme and the
# version-stack default. Session-authed (§14d). #show READS five counts (six for an admin) and the
# library folder's name, and writes nothing. The hub writes ONE preference, in #update: the account's
# version-stack default, a column on the user's own row. The theme is not a write here — it is a
# cookie the client writes (design-system.md rule 7) — and making rows (a user's shelves, the
# thirteen-role filing map they derive from) stays on the Shelves page itself
# (Maker::Shelves.ensure!), where a visit means "show me my shelves," not here: a bare count must not
# seed 82 filing rules as a side effect of loading the hub. The Filing row went in 2026-10-20, when
# Filing became Shelves.
class SettingsController < ApplicationController
  def show
    # The Library row (K): the chosen folder on share, what the library is on the other two.
    @library_fact =
      if Tinkerex::LibraryRoot.share?
        rel = Tinkerex::LibraryRoot.relative
        rel.present? ? "/#{rel}" : "whole folder"
      else
        capabilities.presignable? ? "server storage" : "sync server"
      end
    @shelf_count = Maker::Shelves.count_for(current_user)
    @supplier_count = current_user.maker_suppliers.count
    @location_count = current_user.maker_locations.count
    @tag_count = current_user.maker_tags.count
    # The Devices row (pentest H1b, 2026-10-22): the desktop apps signed in to this account.
    @device_count = current_user.devices.count
    # The Users row (2026-10-21) renders for an admin only, so only an admin pays for the count.
    @user_count = User.count if current_user.can_manage_accounts?
  end

  # PATCH /settings — the account's master default for version stacks (2026-11-24), which every
  # project follows unless it chose for itself (Maker::Project#stacking?, the project's Edit page)
  # and which the Library and Search read directly. Two answers, "1" and "0"; anything else writes
  # nothing, and the notice still says what the default is, so the page never claims a change it
  # did not make.
  def update
    value = params[:stack_versions].to_s
    current_user.update!(stack_versions: value == "1") if %w[0 1].include?(value)
    redirect_to settings_path,
                notice: (current_user.stack_versions ? "Versions stack by default." : "Versions don't stack by default.")
  end
end
