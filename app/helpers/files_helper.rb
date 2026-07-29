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
  # (FilesController#sort_key's "type" branch): the file's extension, or "Symlink" for a symlink.
  # This column used to be headed "Kind" and render `node.kind`, which is the word "file" on every
  # file row -- made sortable without this change, it would be a column whose every value is
  # identical while the rows around it reorder, so the sort would read as broken and the header
  # would be naming something it does not show.
  #
  # A directory says "Folder" rather than "dir": it is the one row with no extension to show, and
  # the sort groups directories together regardless of key. An extension-less file gets the same
  # em-dash every other empty cell in this table uses.
  #
  # A SYMLINK SAYS SO, rather than showing the extension of whatever it is named after. `symlink`
  # is a first-class Node::KIND that git-on-mount depends on, and the column this replaced said
  # "symlink" plainly; falling through to the file branch would have quietly reclassified them.
  # THE SORT AGREES: sort_key answers the literal "symlink" for one, so a Type sort groups them
  # rather than scattering them through the extension they end in. It did not until a review drove
  # it, and the invariant above was contradicted two lines below itself -- the cell said "Symlink"
  # while the key said "stl", so the row sorted into the middle of the STL block. (They still sit
  # in the FILE block rather than with the folders; that is sort_nodes' partition, a separate
  # question.)
  def file_type_label(node)
    return "Folder" if node.dir?
    return "Symlink" if node.symlink?

    File.extname(node.name).delete(".").upcase.presence || "—"
  end

  # DERIVED, not hand-written, and that is the point. These chips and the project Files panel's
  # headings were two independent lists that disagreed: `.svg`/`.dxf`/`.lbrn2` read "2D / laser"
  # here and "Vector" there, and the five cad_source extensions had no chip at all. One source of
  # truth now — Maker::FileAttachment's ROLE_BY_EXT for the grouping, ROLE_LABELS for the label and
  # the order — so they cannot drift again. Pinned by test/helpers/files_helper_test.rb.
  #
  # `other` drops out on its own: it is the fallback for UNRECOGNISED extensions, so no extension
  # maps to it and filter_map skips the empty family rather than rendering an empty labelled row.
  EXT_FAMILIES = Maker::FileAttachment::ROLE_LABELS.filter_map { |role, label|
    exts = Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, r| r == role }.keys.freeze
    [ label, exts ] if exts.any?
  }.to_h.freeze

  # The URL for toggling `ext` into or out of the active set.
  #
  # NEITHER `folder` NOR `sort`/`dir` RIDES ALONG, and both omissions are the same argument
  # files_query_base makes about `view`. `folder` because activating a filter LEAVES the folder
  # (see #index), so carrying it would put a param in the URL that the request then ignores.
  # `sort`/`dir` because they are cookie-persisted: pinning them would freeze into a copied or
  # bookmarked chip URL a choice the user can still change from the headers.
  def ext_toggle_path(ext, active_exts)
    toggled = active_exts.include?(ext) ? active_exts - [ ext ] : active_exts + [ ext ]
    files_path({ ext: toggled.presence&.join(",") }.compact)
  end

  # Can another extension still be turned on? `resolve_exts` keeps only the FIRST MAX_EXTS, so
  # once the set is full an inactive chip's URL would append a value the controller silently drops
  # — a control that renders, links, and does nothing. The row renders those inert instead.
  #
  # THE FREE-TEXT FIELD BESIDE THE CHIPS ASKS THIS TOO, and it did not until a review drove it:
  # submitting `add_ext=lbrn2` with eight already active returned the same eight chips and no
  # `.lbrn2`, two inches from a `.lbrn2` chip correctly rendered inert for that exact reason. One
  # predicate, both controls.
  def ext_slots_left?(active_exts) = active_exts.size < FilesController::MAX_EXTS

  # The one sentence both full-set controls say. DEFINED ONCE because they are two controls
  # answering one condition, and the failure being fixed here is precisely the two of them
  # answering it differently — a second copy of this string is how they would drift again.
  def ext_limit_title
    "Turn one off first — at most #{FilesController::MAX_EXTS} types at a time."
  end
end
