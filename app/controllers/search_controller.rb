# One search over everything the web app shows (stage 2, S2-5). Read-only, session-authed —
# ApplicationController's default-deny `authenticate_user!` covers this like every other web
# controller (CLAUDE.md §14d); there is no v1/device-token door here. Each kind is ONE capped
# query plus ONE count, in the Files idiom (`FilesController#resolve_query`/`#index`'s `?q=`
# clause): `LOWER(col) LIKE ? ESCAPE '\'`, the pattern built with `sanitize_sql_like` — without
# the ESCAPE clause SQLite reads the backslash as a literal and the sanitizing is a no-op on
# self-host (the exact measurement lives on that clause's own comment in files_controller.rb).
#
# Every scope below reads off `current_user` (or `current_user.nodes`), never a bare model class,
# so tenancy is ordinary Rails user_id scoping (§8) — the same shape as the Files search this
# reuses the idiom from.
class SearchController < ApplicationController
  # Same bound as FilesController::QUERY_MAX, for the same reason: an unbounded query string
  # would build an unbounded LIKE pattern for no user-visible benefit.
  QUERY_MAX = 80
  # Five per kind on the results page; each group's own index ("See all") shows the rest.
  PER_GROUP = 5

  def index
    @q = params[:q].to_s.strip.first(QUERY_MAX)
    @groups = []
    return if @q.blank?

    like = "%#{Node.sanitize_sql_like(@q.downcase)}%"

    # Files: live, visible nodes only — `.present` excludes tombstones, `visible_entries(false)`
    # excludes dot-files and the `.git` marker, exactly like a folder view with hidden files off.
    # `kind: "file"` only: a directory has nowhere useful of its own to preview in a results row.
    files = current_user.nodes.present.where(kind: "file")
                        .visible_entries(false)
                        .where("LOWER(name) LIKE ? ESCAPE '\\'", like)
    add_group("Files", :file, files.order(:name), files_path(q: @q))

    # Projects: name OR description. Archived projects are the user's own and are not excluded
    # here — only the "See all" destination (the projects index) hides them by default; said
    # once, not re-litigated per row.
    projects = current_user.maker_projects
                           .where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(description) LIKE ? ESCAPE '\\'",
                                  like, like)
    add_group("Projects", :project, projects.order(:name), projects_path(q: @q))

    # Models: title only. `catalogued` excludes a dismissed auto model, the same filter the
    # Models index itself applies.
    models = current_user.maker_models.catalogued.where("LOWER(title) LIKE ? ESCAPE '\\'", like)
    add_group("Models", :model, models.order(:title), models_path(q: @q))

    # Inventory: name OR part number, mirroring InventoryItemsController#index's own clause.
    items = current_user.maker_inventory_items
                        .where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(part_number) LIKE ? ESCAPE '\\'",
                               like, like)
    add_group("Inventory", :inventory_item, items.order(:name), inventory_items_path(q: @q))

    # Tags: no LOWER() needed — Maker::Tag normalizes `name` (stripped, downcased) at write time,
    # and `like` is already built from the downcased query, so a plain LIKE already compares two
    # lowercase strings. No "See all": there is no tag index page to link a remainder into, so
    # more_path is nil and a sixth tag simply never displays (Tags rarely numbers more than a
    # handful per query in practice, and the tag page itself is the "more" for any one tag).
    tags = current_user.maker_tags.where("name LIKE ? ESCAPE '\\'", like)
    add_group("Tags", :tag, tags.order(:name), nil)
  end

  private

  # Skips a kind entirely when it has no matches, so the view never renders an empty
  # `.result-group--<kind>` shell. `total` (not `records.size`) is what "See all N" reads --
  # the count is a second, unbounded query, but it is ONE per kind, same shape as the Files page's
  # own @match_count.
  def add_group(title, kind, scope, more_path)
    total = scope.count
    return if total.zero?
    @groups << { title:, kind:, records: scope.limit(PER_GROUP).to_a, total:, more_path: }
  end
end
