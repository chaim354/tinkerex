# The settings hub (stage 2, S2-6; the Library row added in K, the admins-only Users row on
# 2026-10-21). One door onto the library folder, the reference pages, the accounts, the account page
# and the theme. Session-authed (§14d). It READS four counts
# (five for an admin) and the library folder's name, and writes nothing — the theme is a cookie the client writes
# (design-system.md rule 7), and making rows (a user's shelves, the thirteen-role filing map they
# derive from) stays on the Shelves page itself (Maker::Shelves.ensure!), where a visit means "show
# me my shelves," not here: a bare count must not seed 82 filing rules as a side effect of loading
# the hub. The Filing row went in 2026-10-20, when Filing became Shelves.
class SettingsController < ApplicationController
  def show
    # The Library row (K): the chosen folder on share, what the library is on the other two.
    @library_fact =
      if Tinkerex::LibraryRoot.share?
        rel = Tinkerex::LibraryRoot.relative
        rel.present? ? "/#{rel}" : "whole folder"
      else
        capabilities.presignable? ? "storage bucket" : "sync server"
      end
    @shelf_count = Maker::Shelves.count_for(current_user)
    @supplier_count = current_user.maker_suppliers.count
    @location_count = current_user.maker_locations.count
    @tag_count = current_user.maker_tags.count
    # The Users row (2026-10-21) renders for an admin only, so only an admin pays for the count.
    @user_count = User.count if current_user.can_manage_accounts?
  end
end
