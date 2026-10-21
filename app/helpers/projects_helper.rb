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
  BLOCK_LABELS = { "text" => "Text block", "link" => "Link", "image" => "Image" }.freeze

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
                    "sheets" => "project-sheets" }.freeze

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
end
