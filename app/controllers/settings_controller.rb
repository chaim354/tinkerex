# The settings hub (stage 2, S2-6; the Filing row added in stage 3, S3-1, the Library row in K). One
# door onto the library folder, the reference pages, the account page and the theme. Session-authed
# (§14d). It READS five counts and the library folder's name, and
# writes nothing — the theme is a cookie the client writes (design-system.md rule 7), and seeding
# (default shelves, the thirteen-role filing map) stays on each row's OWN page, where a visit means
# "show me my X," not here: a bare count must not seed 82 filing rules as a side effect of loading
# the hub.
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
    @shelf_count = current_user.maker_shelves.count
    @supplier_count = current_user.maker_suppliers.count
    @location_count = current_user.maker_locations.count
    @filing_rule_count = current_user.maker_filing_rules.count
    @tag_count = current_user.maker_tags.count
  end
end
