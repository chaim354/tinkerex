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

  # The maker's title, else the default label — Maker::Project::PANEL_LABELS for a fixed key, the
  # folder's own name for a folder key, which only the caller knows.
  def panel_title(layout, key, default = nil)
    layout.title_for(key, default || Maker::Project::PANEL_LABELS.fetch(key.to_s))
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
