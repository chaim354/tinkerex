module FilesHelper
  # A sortable column header. Clicking the ACTIVE column flips its direction; clicking any other
  # starts it ascending. `extra` carries the folder and filter params so sorting never drops
  # them -- FilesController#files_query_base is the one place that set is decided.
  #
  # aria-sort is what makes this usable with a screen reader -- a "▲" in the label is invisible to
  # one, and a column that announces no sort state is a column you cannot navigate. Every header
  # carries it, including the inactive ones ("none"), because a table where only one `th` has the
  # attribute reads as a table whose other columns are not sortable at all.
  def sort_header(label, key, current_sort, current_dir, extra = {})
    active = current_sort == key
    next_dir = (active && current_dir == "asc") ? "desc" : "asc"
    arrow = active ? (current_dir == "asc" ? " ▲" : " ▼") : ""
    aria  = active ? (current_dir == "asc" ? "ascending" : "descending") : "none"
    tag.th("aria-sort": aria, class: ("sorted" if active)) do
      link_to("#{label}#{arrow}", files_path(extra.merge(sort: key, dir: next_dir)))
    end
  end

  # WHAT THE "Type" COLUMN SHOWS, AND IT MUST AGREE WITH WHAT THE "Type" HEADER SORTS BY
  # (FilesController#sort_key's "type" branch): the file's extension. This column used to be
  # headed "Kind" and render `node.kind`, which is the word "file" on every file row -- made
  # sortable without this change, it would be a column whose every value is identical while the
  # rows around it reorder, so the sort would read as broken and the header would be naming
  # something it does not show.
  #
  # A directory says "Folder" rather than "dir": it is the one row with no extension to show, and
  # the sort groups directories together regardless of key. An extension-less file gets the same
  # em-dash every other empty cell in this table uses.
  def file_type_label(node)
    return "Folder" if node.dir?

    File.extname(node.name).delete(".").upcase.presence || "—"
  end

  # The chip row's vocabulary: extensions this app already knows something about — it can thumbnail
  # them (Maker::Previews::Registry::RENDERERS), give them a role on a project
  # (Maker::FileAttachment::ROLE_BY_EXT) or preview them on the file page
  # (FilesController#preview_kind) — grouped so the row reads as a maker's shelf rather than an
  # alphabet.
  #
  # HAND-PICKED, NOT DERIVED from those three, and that is the point rather than laziness: their
  # union includes `rb`, `cpp`, `yaml` and `markdown`, which is a programmer's file list, not the
  # shelf a maker wants to click. Only `csv` here comes from just one of them (#preview_kind).
  #
  # A CURATED LIST, NOT REAL FACET COUNTS, and the reason is cost: counting "you have 214 .stl
  # files" means plucking every filename in the library on EVERY Files page load, including plain
  # folder browsing that never looks at the chips. A chip that matches nothing is a harmless dead
  # end; a query the folder view pays for and never reads is not. The free-text field beside the
  # row is what covers a format this list has never heard of.
  #
  # Every value here must satisfy FilesController::EXT_RE — a chip the controller then drops is a
  # control that renders, links, and silently does nothing. files_type_filter_test.rb's "every
  # chip in the row is an extension the controller actually accepts" clicks all of them.
  EXT_FAMILIES = {
    "3D models"  => %w[stl 3mf obj step stp],
    "2D / laser" => %w[svg dxf lbrn2],
    "Documents"  => %w[pdf txt md csv],
    "Images"     => %w[png jpg jpeg webp],
    "Machine"    => %w[gcode zip]
  }.freeze

  # The URL for toggling `ext` into or out of the active set, preserving the sort. `folder` is
  # deliberately NOT preserved: activating a filter LEAVES the folder (see #index), so carrying it
  # would put a param in the URL that the request then ignores.
  def ext_toggle_path(ext, active_exts, sort, dir)
    toggled = active_exts.include?(ext) ? active_exts - [ ext ] : active_exts + [ ext ]
    files_path({ ext: toggled.presence&.join(","), sort:, dir: }.compact)
  end
end
