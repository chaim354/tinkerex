module FilesHelper
  # A sortable column header. Clicking the ACTIVE column flips its direction; clicking any other
  # starts it ascending. `extra` carries the folder params so sorting never drops them --
  # FilesController#files_query_base is the one place that set is decided.
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
end
