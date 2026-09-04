# THE "EDIT IN <ADDON>" LINK FOR A PAGE OF LIBRARY NODES — the controller half of
# Maker::AddonOrigin, shared by the three actions that render a file (FilesController#index,
# FilesController#show, ProjectsController#show) rather than written out three times.
#
# TWO STEPS, AND THE ORDER IS THE POINT: the cheap indexed query FIRST, and the Registry — a
# manifest fetch over HTTP behind a 5-minute cache — ONLY if that query found something. A library
# with no addon output must never make an addon-source outage into a slow Files page for a user who
# has never opened /tools. Maker::AddonOrigin proved its own half of that property (it makes no
# Registry call at all); this method is where the other half lives, and
# test/integration/web/addon_origin_surfaces_test.rb pins it with a counting double through a real
# request — the ordering is a property of a private controller method, so only driving the page
# exercises it.
#
# A COUNTING DOUBLE, NOT A RAISING ONE. `Registry.manifests` rescues StandardError and answers [],
# so a stub that raises on `manifests` would be SWALLOWED and the regression would pass — the same
# note Maker::AddonOriginTest carries for the same reason.
module AddonOrigins
  extend ActiveSupport::Concern

  private

  # Returns { node_id => { url:, label:, state: } }, with an ABSENT KEY for every node no addon
  # produced and for every node whose addon this deployment no longer serves. The three menu surfaces
  # read it with `dig`, and a nil there renders no data attribute at all — which is exactly how a
  # surface opts out of the right-click entry (see filemenu_controller.js); files/show.html.erb takes
  # the whole entry, because it needs the state's own name and revision as well.
  #
  # `label` IS BUILT HERE, ONCE, AND THAT IS DELIBERATE. The same sentence appears on four surfaces
  # (the Files list, the Files grid, a project's attachment tiles, and the file page's own button);
  # written at each site it would be four copies of user-facing prose free to drift apart, which is
  # §14d's one-vocabulary rule applied to a sentence instead of an extension list. `title` is not
  # passed through beside it because nothing renders the bare addon name today — add it here when
  # something does, rather than shipping a key no view reads.
  #
  # A BUILT Addon ALWAYS HAS A TITLE (`Registry::REQUIRED` includes it and `build` returns nil
  # without it), so there is no "Edit in " with nothing after it to guard against here.
  def addon_origins_for(node_ids)
    origins = Maker::AddonOrigin.for(user: current_user, node_ids:)
    return {} if origins.empty?

    addons = Maker::Addons::Registry.all
    origins.filter_map { |node_id, state|
      link = Maker::AddonOrigin.link_for(state, addons:)
      next if link.nil?

      [ node_id, { url: link[:url], label: "Edit in #{link[:title]}", title: link[:title], state: } ]
    }.to_h
  end
end
