# The project page's panel headings (2026-09-09, the page editor; spec §3). Two helpers rather
# than each partial reaching into the layout, so a title's fallback and an intro's markup are
# written once for the maker's page and the visitor's. The LAYOUT IS AN ARGUMENT: the maker's page
# holds @panel_layout, the public page holds `pub.layout`, and the shared projects/_wiring partial
# is handed whichever it is rendering for as a local.
module ProjectsHelper
  # WHAT THE EDITOR CALLS ONE BLOCK (2026-09-09, content blocks). A block has no PANEL_LABELS entry
  # and no folder name to fall back on, and the kind alone repeats on every block of that kind —
  # the heading is the only thing telling two text blocks apart in a strip's aria label. A HELPER
  # rather than a controller method because BOTH sides need it: ProjectsController#show builds
  # @panel_labels from it, and projects/_block_templates labels a slot whose key names no row.
  BLOCK_LABELS = { "text" => "Text block", "link" => "Link", "image" => "Image", "file" => "File" }.freeze

  # A FILE BLOCK'S SANDBOX FRAME ON THE MAKER'S OWN PAGE (2026-11-19, embedded files): the sandbox
  # door's URL under an owner token for an HTML file, nil for any other file (which frames
  # FilesController#embed instead). A fresh token per render, like the file page's.
  def file_block_frame_url(node)
    return nil unless Maker::FileAttachment.html?(node.name)

    sandbox_path(Maker::HtmlSandbox.token_for(owner: current_user, node:), node.name)
  end

  def block_label(block)
    name = BLOCK_LABELS.fetch(block.kind, "Block")
    block.heading.present? ? "#{name}: #{block.heading}" : name
  end

  # WHERE "+ ADD PANEL" LANDS (structural redesign §6, slice 6): each on-demand panel's own element
  # id, so the link opens the panel and scrolls to it — and tabs_controller.js shows the pane a
  # panel's own anchor sits in. `project-tasks` is also Projects::TasksController's turbo-stream
  # target and must not be renamed; the other five ids exist for this map. Keyed exactly as
  # ProjectsController::ON_DEMAND, which `fetch` holds it to.
  PANEL_ANCHORS = { "build_log" => "project-build-log", "tasks" => "project-tasks", "bom" => "project-bom",
                    "wiring" => "project-wiring", "releases" => "project-releases",
                    "sheets" => "project-sheets", "calculations" => "project-calculations" }.freeze

  # SORT BY STATUS IS THE LIFECYCLE, NOT THE ALPHABET (2026-11-02, the UX audit's C10). The list's
  # SQL sort (ProjectsController::SORTS["status"]) is `status: :asc`, which put Active before Done
  # before Paused before Planning; Maker::Project::STATUSES is the lifecycle order, so the "status"
  # sort is re-ordered here by it, in memory over the page's own array, with name and id as the
  # tiebreak the SQL sort already uses. Every other sort passes through untouched.
  def projects_in_order(projects, sort)
    return projects unless sort == "status"

    projects.sort_by { |p| [ Maker::Project::STATUSES.index(p.status) || Maker::Project::STATUSES.size, p.name.to_s, p.id ] }
  end

  # IS THIS PANEL ON THE PAGE BEING RENDERED (2026-11-02, the UX audit's C7)? Visible in the layout
  # and not one of ProjectsController#show's absent on-demand panels (empty, and not opened with
  # ?add=). The stats line counts a panel's rows only when this is true, so it never counts what
  # the maker cannot see below it. `absent` is nil in the editor, where every visible panel draws.
  def panel_on_page?(layout, key, absent)
    layout.visible?(key) && !Array(absent).include?(key)
  end

  # The panels the project's TYPE hides that still hold rows (Maker::ProjectHiddenRows), once per
  # render, for the hub's "Also in this project" line. Asked here rather than in
  # ProjectsController#show, whose file is not this feature's; a controller that sets @hidden_rows
  # itself is used as-is. The sheets ride in from the page's own load, so they cost no query.
  def project_hidden_rows
    @hidden_rows ||= Maker::ProjectHiddenRows.for(project: @project, layout: @panel_layout, sheets: @sheets)
  end

  # What "Also in this project" calls one hidden panel: its rows in the maker's words ("1 release",
  # "2 connections"), and the BOM under its own heading, because "3 lines" alone names nothing.
  HIDDEN_ROW_NOUNS = { "build_log" => "build log entry", "tasks" => "task", "wiring" => "connection",
                       "releases" => "release", "sheets" => "sheet", "calculations" => "saved calculation" }.freeze

  def hidden_row_label(entry, layout)
    if entry.key == "bom"
      "#{panel_title(layout, 'bom')} (#{pluralize(entry.count, 'line')})"
    else
      pluralize(entry.count, HIDDEN_ROW_NOUNS.fetch(entry.key))
    end
  end

  # Where one opens: the panel's own page where it has one — the BOM page, the one sheet — else the
  # layout editor at that panel, whose strip holds its Show control.
  def hidden_row_path(project, entry)
    return project_bom_path(project) if entry.key == "bom"
    return sheet_path(entry.sheet_id) if entry.sheet_id

    edit_layout_project_path(project, anchor: PANEL_ANCHORS.fetch(entry.key))
  end

  # The maker's title, else the default label — Maker::Project::PANEL_LABELS for a fixed key, the
  # folder's own name for a folder key, which only the caller knows.
  def panel_title(layout, key, default = nil)
    layout.title_for(key, default || Maker::Project::PANEL_LABELS.fetch(key.to_s))
  end

  # THE SHELF-GROUP HEADINGS (2026-10-20). Yields each key for its slot markup and draws a heading
  # before every run of consecutive RENDERED panels whose folder's shelf is in the same group. A
  # panel that renders nothing (the visitor's page omits empty ones) neither draws nor breaks a
  # run, which is why the heading is decided here, after the body is known, and not from the keys.
  # Each key is yielded ONCE (projects/_panel_groups' rule), and a call is one grid: a run never
  # continues across two calls, so a group a tab splits is headed in each grid it lands in.
  def panels_with_group_heads(keys, layout)
    previous = nil
    parts = keys.filter_map do |key|
      body = yield(key)
      next if body.blank?

      group = layout.shelf_group_for(key)
      head = tag.h2(group, class: "group-head shelf-group-head") if group && group != previous
      previous = group
      safe_join([ head, body ].compact)
    end
    safe_join(parts)
  end

  # A TEXT BLOCK'S MARKDOWN ON THE MAKER'S PAGE: relative links resolve against the project folder
  # the way the README does, a link opens the file's page and a picture loads its bytes (C2 —
  # `![x](docs/plate.svg)` pointed at the HTML page drew a broken image). The same two arms as the
  # README panel, through Maker::Readme.render_markdown, so the block and the panel cannot disagree.
  def project_markdown(text, listing)
    Maker::Readme.render_markdown(text.to_s, base_path: listing.path, index: listing.path_index,
                                  link: Maker::RepoCard::DEFAULT_LINK, image_link: maker_image_link(listing, @page_thumbs))
  end

  # THE MAKER'S PICTURE OF A FILE, BY NODE (2026-11-05, live regions; spec §5). An image file is its
  # bytes — the blob route, the door the hero and an image block already load from; any other file is
  # its READY thumbnail, where `![x](models/base.stl)` used to render the model's bytes as a broken
  # picture. nil DROPS the <img> (Maker::Readme.render_markdown), which is why Live::ImageLine writes
  # a LINK rather than an image while no thumbnail is ready. `listing` says which node a resolved id
  # is; `thumbs` is the page's one ThumbnailMap (nil on a render that built none — then every
  # non-image picture is dropped rather than broken). A node the listing does not hold cannot have
  # been resolved by the folder resolver at all, so that arm is defensive, not reachable.
  #
  # WHICH FILES ARE PICTURES IS `Maker::Readme::Live.picture?`'s ONE ANSWER — the inline-image list
  # plus SVG, which `![plate](docs/plate.svg)` has drawn from the blob route since the UX audit's C2
  # (project_hub_audit_test.rb pins it, for a README and a text block alike); keyed on
  # `inline_image?` alone, an SVG with no thumbnail yet would vanish from the page instead of drawing.
  def maker_image_link(listing, thumbs)
    lambda do |id|
      row = listing.row_for(id)
      next blob_file_path(id) if row.nil? || Maker::Readme::Live.picture?(row.node.name)

      thumb = thumbs&.thumb(id)
      thumb&.showable? ? preview_src(thumb) : nil
    end
  end

  # One muted line under the heading, or nothing. Escaped by `content_tag`; an intro is text.
  def panel_intro(layout, key)
    intro = layout.intro_for(key)
    content_tag(:p, intro, class: "panel-intro muted") if intro
  end

  # A LINK BLOCK'S HOST, AS WRITTEN (2026-09-09, content blocks; spec §2): the card shows where the
  # link goes, which is the one thing a title cannot lie about. `www.` IS KEPT — it is part of what
  # the maker typed and part of what the browser will show, and stripping it makes the card and the
  # address bar disagree for exactly the sites that use it.
  #
  # TOTAL, LIKE EVERY OTHER READ OF A COLUMN NOTHING VALIDATES ON THE WAY IN: `url` is checked by
  # Maker::ProjectBlock and by Maker::LayoutDocument, but a row written by a console or an older
  # version must still render a page, so an unparseable URL is an empty host, never a 500. The
  # browser's own `drawLinkCard` (layout_editor_controller.js) does the same with `new URL`.
  def link_host(url)
    URI.parse(url.to_s).host.to_s
  rescue URI::Error
    ""
  end

  # A FOLDER PANEL'S TURBO FRAME (2026-11-24, click-through panels). Not the layout key itself: the
  # section inside keeps that id, because anchors land on it and the tests and the editor name it.
  # ProjectsController#frame_panel_key matches a frame request's id against this, and
  # #switched_panel_streams replaces a folder panel by it.
  #
  # A PLAIN CSS IDENTIFIER, NEVER THE KEY'S OWN SPELLING: `folder:<id>` carries a colon, and Turbo
  # (turbo-rails 2.0.23, FrameController#visitCachedSnapshot) finds a frame in the snapshot it caches
  # for Back with an UNESCAPED `querySelector("#" + id)`, where a colon reads as a pseudo-class. The
  # lookup throws, the snapshot keeps the folder the visit left, and Back shows the wrong one —
  # found by project_panel_navigation_test.rb, not by any request test.
  def panel_frame_id(key) = "frame-#{key.to_s.gsub(/[^A-Za-z0-9_-]/, '-')}"

  # THE `at` A LINK CARRIES (2026-11-24): every panel's open folder as this render has it
  # (@panel_at, ProjectsController#show), with one panel moved to `node_id` — or back to its own
  # folder, which is no entry at all. nil when nothing is open, so the link is the bare page.
  def panel_at(panel_id, node_id)
    at = (@panel_at || {}).merge(panel_id => node_id)
    at.reject { |pid, id| id.nil? || id == pid }.presence
  end

  # WHAT A FOLDER LINK IN A PANEL CARRIES: it opts INTO the panel's frame (which is `_top` for every
  # other link inside it) and advances the URL, so Back steps out of the folder.
  def panel_folder_link_data(key) = { turbo_frame: panel_frame_id(key), turbo_action: "advance" }

  # ONE VERSION STACK AMONG A PANEL'S FIGURES (2026-11-19): the stack and its members' rows,
  # latest first, so a tile or a list row can draw the latest and open onto the rest.
  StackFigure = Data.define(:stack, :rows) do
    def latest = rows.first
  end

  # WHAT A PANEL'S GROUP DRAWS, IN ORDER: each Row that stands alone, and a StackFigure where a
  # stack's first member stood (Maker::VersionStacks::Result#collapse over ProjectsController#show's
  # @stacks). `folder_id` names the folder these rows sit in, so the backups that stack with them
  # (@stacked_backups) join them here rather than in the Files panel's Backups group. A panel whose
  # switch is off has no stacks in @stacks, so its rows come back as they went in. A stack missing a
  # member's row (it cannot, the rows are what was grouped) is drawn as the rows it has.
  def stack_figures(rows, folder_id: nil)
    all = rows + Array(@stacked_backups&.fetch(folder_id, nil))
    return all if @stacks.nil? || @stacks.stacks.empty?

    by_id = all.index_by(&:node_id)
    @stacks.collapse(all.map(&:node_id)).flat_map do |figure|
      next [ by_id[figure] ] unless figure.is_a?(Maker::VersionStacks::Stack)

      members = figure.node_ids.filter_map { |id| by_id[id] }
      members.size == figure.size ? [ StackFigure.new(stack: figure, rows: members) ] : members
    end
  end
end
