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
    # excludes dot-files, the `.git` marker and, since stage 4, S4-2, build-output directories
    # (`Library::BuildOutput`), exactly like a folder view with hidden files off.
    # `kind: "file"` only: a directory has nowhere useful of its own to preview in a results row —
    # which is also why the build-output rule, a DIRECTORY rule, changes nothing this query returns
    # and is pinned on the Files page's own flat `?q=` instead (files_search_test.rb).
    files = current_user.nodes.present.where(kind: "file")
                        .visible_entries(false)
                        .where("LOWER(name) LIKE ? ESCAPE '\\'", like)
    add_group("Files", :file, files.order(:name), files_path(q: @q))

    # Folders: the DIRECTORY rows the Files group deliberately excludes, as their own kind. This is
    # story 3.5's "folder paths" half, in the only spelling all three backends can answer:
    # `nodes.storage_path` -- the obvious one -- is written by FileLayer::Share and FileLayer::S3
    # ONLY (chunk_remote mirrors a remote tree and never writes it), so a LIKE over it would be
    # structurally empty on the product's main deployment: one condition with two answers across
    # backends, which §14a forbids and which no test leg could pin identically. A folder row links
    # into the Files page's own folder view, which is the thing the maker was looking for.
    #
    # `visible_entries(false)`: the same display filter the Files group applies, so a dot-dir, the
    # `.git` marker and a build-output directory are as absent here as they are on a folder page.
    # KNOWN LIMITATION, INHERITED VERBATIM FROM THAT SCOPE AND NOT WORSENED HERE: `.git` is
    # excluded BY NAME, so on chunk_remote -- where the desktop client syncs the marker's contents
    # and they exist as rows -- a directory INSIDE `.git` still matches by its own name. Node's own
    # comment records why closing that needs a recursive CTE this page must not pay for; on share
    # and s3 nothing beneath the marker is observed, so there are no rows to match at all.
    folders = current_user.nodes.present.where(kind: "dir")
                          .visible_entries(false)
                          .where("LOWER(name) LIKE ? ESCAPE '\\'", like)
    # No "See all": the Files index has no folder-only listing to send a remainder to.
    add_group("Folders", :folder, folders.order(:name), nil)

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

    # Notes: the note BODY, which is the one thing a maker writes that this app keeps and could not
    # find (story 3.5). It lives in `action_text_rich_texts`, reached through the `rich_text_body`
    # association `has_rich_text :body` already declares -- `joins(:rich_text_body)` emits both
    # `record_type = 'Maker::Note'` and `name = 'body'` itself (probed), so a hand-written ON clause
    # here would be a second spelling that can drift from the association.
    #
    # ONLY NOTES ON A LIVE FILE, because the row's whole content is a link to that file's page. The
    # `.present` subquery is one statement and adapter-agnostic; a boolean literal inside a JOIN
    # condition is not.
    #
    # README TEXT IS DELIBERATELY NOT HERE, and the reason is a measurement rather than a
    # preference: Maker::Readme reads a README through the PORT at request time from an in-memory
    # ProjectFolderListing, so searching them costs one listing plus one port read PER PROJECT --
    # on chunk_remote a WAN stream each. page_query_budget_test.rb's search#index case grows
    # projects and asserts constancy in N, so that shape fails a guard by construction. README
    # search needs a stored, scan-maintained index; that is a design, not a group. Story 3.5
    # records it as remaining friction.
    notes = current_user.maker_notes
                        .joins(:rich_text_body)
                        .where(node_id: current_user.nodes.present.select(:node_id))
                        .where("LOWER(action_text_rich_texts.body) LIKE ? ESCAPE '\\'", like)
                        .includes(:rich_text_body)
                        .order(created_at: :desc)
    if (group = add_group("Notes", :note, notes, nil))
      # THE FILE NAMES FOR THE ROWS THAT WILL ACTUALLY RENDER -- one query over at most PER_GROUP
      # ids, after the cap. Doing it in the scope instead would need a `select`, and a relation
      # carrying select values breaks `add_group`'s own `.count` (`COUNT(a, b)` is not SQL).
      group[:node_names] = current_user.nodes.where(node_id: group[:records].map(&:node_id))
                                       .pluck(:node_id, :name).to_h
    end

    # Inventory: name OR part number, mirroring InventoryItemsController#index's own clause.
    # `includes(:location)`: a result row says where the item lives; five rows, five lookups without it.
    items = current_user.maker_inventory_items.includes(:location)
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
  #
  # RETURNS THE GROUP, OR nil WHEN THERE WERE NO MATCHES. The Notes group needs one more query
  # after the cap is applied (the file names for the five rows it will actually render), and that
  # query must see the CAPPED set, not the whole match set -- so the caller needs the hash back.
  # Every other caller ignores the return value, exactly as before.
  #
  # A SCOPE HANDED IN HERE MUST CARRY NO `select` VALUES: `.count` on such a relation builds
  # `COUNT(a, b)`, which is not SQL. That is why the Notes group's file names are a second query
  # over the capped ids rather than a column on the scope itself.
  def add_group(title, kind, scope, more_path)
    total = scope.count
    return if total.zero?

    group = { title:, kind:, records: scope.limit(PER_GROUP).to_a, total:, more_path: }
    @groups << group
    group
  end
end
