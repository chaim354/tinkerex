# The settings hub (stage 2, S2-6; the Filing row added in stage 3, S3-1). One door onto the
# reference pages, the account page and the theme. Session-authed (§14d). It READS five counts and
# writes nothing — the theme is a cookie the client writes (design-system.md rule 7), and seeding
# (default shelves, the eleven-role filing map) stays on each row's OWN page, where a visit means
# "show me my X," not here: a bare count must not seed 82 filing rules as a side effect of loading
# the hub.
class SettingsController < ApplicationController
  def show
    @shelf_count = current_user.maker_shelves.count
    @supplier_count = current_user.maker_suppliers.count
    @location_count = current_user.maker_locations.count
    @filing_rule_count = current_user.maker_filing_rules.count
    @tag_count = current_user.maker_tags.count
  end
end
