# The settings hub (stage 2, S2-6): one door onto the reference pages, the account page and the
# theme. Session-authed (§14d). It READS four counts and writes nothing — the theme is a cookie the
# client writes (design-system.md rule 7), and the seeding of default shelves stays on the shelves
# page, where a visit means "show me my shelves", not here.
class SettingsController < ApplicationController
  def show
    @shelf_count = current_user.maker_shelves.count
    @supplier_count = current_user.maker_suppliers.count
    @location_count = current_user.maker_locations.count
    @tag_count = current_user.maker_tags.count
  end
end
