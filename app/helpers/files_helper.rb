module FilesHelper
  # A sortable column header. Clicking the ACTIVE column flips its direction; clicking any other
  # starts it ascending. `extra` carries the folder and filter params so sorting never drops
  # them -- FilesController#files_query_base is the one place that set is decided.
  #
  # aria-sort is what makes this usable with a screen reader -- a "▲" in the label is invisible to
  # one, and a column that announces no sort state is a column you cannot navigate. Every header
  # carries it, including the inactive ones ("none"), because a table where only one `th` has the
  # attribute reads as a table whose other columns are not sortable at all.
  def sort_header(label, key, current_sort, current_dir, extra = {}, col: nil)
    active = current_sort == key
    next_dir = (active && current_dir == "asc") ? "desc" : "asc"
    arrow = active ? (current_dir == "asc" ? " ▲" : " ▼") : ""
    aria  = active ? (current_dir == "asc" ? "ascending" : "descending") : "none"
    tag.th("aria-sort": aria, class: [ ("sorted" if active), col ].compact.join(" ").presence) do
      link_to("#{label}#{arrow}", files_path(extra.merge(sort: key, dir: next_dir)))
    end
  end

  # THE RIGHT-CLICK MENU'S WIRE CONTRACT, BUILT ONCE. `filemenu_controller.js` never assembles a URL
  # — it reads these attributes and nothing else — so this hash IS the menu, and a surface that
  # spells it out itself is a surface free to lose an entry silently. That already happened: the
  # menu worked on the Files list while the grid's cards carried no download-url, invisible to a
  # browser test that only ever visits one of them (file_menu_wiring_test.rb's own header records
  # it). The keys are read POSITIONALLY, so representable-but-broken combinations exist. The gate
  # used to be `if (!noteUrl) return`, which made a Download entry with no menu to put it in; since
  # the folder menu landed it asks whether there is ANY entry at all, so the remaining trap runs
  # the other way — an attribute nothing writes is an entry nothing renders, silently.
  #
  # `origin` IS AN ARGUMENT, NOT `@addon_origins`. The three Files-page cells and the project
  # attachment tiles read the same ivar today, but the models page and the project/model cards do
  # not have one — taking it as a parameter is what lets those adopt this without the coupling.
  # A nil origin must yield NIL and not `""`: `tag.a(data: {x: ""})` renders `data-x=""`, and the
  # existing net matches on ATTRIBUTE PRESENCE (`css_select("[data-addon-open-url]")`), so a blank
  # would be counted as a live cell and break the tests that watch this. (It would not, as an
  # earlier note claimed, "produce a menu entry with no href" — `""` is falsy and every consumer is
  # truthiness-guarded, so it produces no entry at all. The reason to keep nil is the test net.)
  #
  # NOT A SHARED `_file_cell` PARTIAL: the four `link_to` block bodies genuinely differ, and only
  # the data hash is the identical part.
  # `node_name` IS READ OFF THE CALLER'S NODE, NEVER LOOKED UP: a lookup here would be a second query
  # per row on a page that renders hundreds. The menu's `confirm` reads it — a missing one degrades
  # to "Delete this item?" rather than to a broken menu.
  #
  # DETAILS (2026-10-21) is the Library with this file selected: its own folder, so the listing
  # FilesController#index renders contains it, and `selected=` its id. A root file has no parent and
  # `files_path` drops the nil. It takes the NODE, not an id and a name, because it now needs the
  # parent too, and every caller already holds the node.
  def file_menu_data(node, origin)
    { action: "contextmenu->filemenu#open",
      node_name: node.name,
      note_url: file_notes_path(node.node_id),
      download_url: blob_file_path(node.node_id, download: 1),
      delete_url: file_path(node.node_id),
      details_url: files_path(folder: node.parent_node_id, selected: node.node_id),
      addon_open_url: origin&.dig(:url),
      addon_open_label: origin&.dig(:label) }
  end

  # A FOLDER'S MENU IS DELETE ALONE, and it is a SEPARATE BUILDER rather than a branch inside the
  # one above because the two payloads share exactly one key. A folder has no note popover, no blob
  # endpoint and no addon origin; handing it `file_menu_data` with four nils would put the decision
  # about what a folder HAS into the CONTROLLER, which cannot see the node.
  #
  # NO `node_id` KEY, DELIBERATELY. `data-node-id` is the THUMB POLL's key (thumb_cell_data below,
  # read by thumbs_controller.js) and a folder has nothing to poll for; writing one here would put
  # folders into the poll's id list for the sake of a selector a test could get another way.
  #
  # THE GATE THAT STOOD HERE IS GONE WITH THE CAPABILITY (2026-09-10). Between the menu shipping and
  # the port learning to cascade, this returned {} unless `dir_deletable?` — because a Delete that
  # cannot delete is the same defect as a Back button that cannot go back, and on share it flashed
  # an internal sentence with a raw node id. Every backend cascades now, so the payload is
  # unconditional and the branch went with the thing it asked.
  def folder_menu_data(node_id, node_name)
    { action: "contextmenu->filemenu#open", node_name:, delete_url: file_path(node_id) }
  end

  # THE POLL CELL'S HALF — what `thumbs_controller.js` reads (`dataset.nodeId`; a cell without one
  # sends `ids=undefined`). Separate from the menu because they are not co-extensive, and MORE so
  # since 2026-09-10: a folder now gets a menu (Delete) and still no cell, a non-renderable file
  # gets the menu and no cell, and four surfaces outside this file's boundary get the cell and no
  # menu.
  #
  # THOSE FOUR ARE THE ADOPTERS, NOT OVERSIGHTS — `projects/_log_entry.html.erb`,
  # `projects/_card.html.erb`, `models/_card.html.erb` and `models/_hero_poster.html.erb` write this
  # payload as RAW HTML ATTRIBUTES today, and none of them is covered by the presence sweeps in
  # file_menu_wiring_test.rb / addon_origin_surfaces_test.rb. They are deliberately left alone here
  # (F-30's stated boundary) and are the reason this builder exists as a separate one at all.
  #
  # `ext_label` IS AN ARGUMENT AND MUST NOT BE DERIVED FROM THE NAME: `_hero_poster` passes `""` and
  # `_log_entry` passes `"IMG"`, neither of which is any file's extension. Deriving it would break
  # both, and would put a second copy of the extension vocabulary here besides (§14d).
  def thumb_cell_data(node_id, ext_label)
    { thumbs_target: "cell", node_id:, ext: ext_label }
  end

  # A FILE TILE IS A SELECTION ITEM FOR DETAILS (2026-10-21). A click opens the file
  # (fileopen_controller.js, through file_open_data) and a double-click opens it in a new tab; the
  # side panel opens from the file menu's Details, which dispatches `filemenu:details` on the tile and
  # is answered here by selection_controller.js#details. Merged into whatever data the tile already
  # carries — its `action` is APPENDED to, never replaced. A FOLDER IS NEVER PASSED THROUGH THIS: a
  # folder click navigates into it.
  def with_selection(data, node_id)
    data.merge(selection_target: "item", selection_id: node_id,
               action: [ data[:action], "filemenu:details->selection#details" ].compact.join(" "))
  end

  # A FILE LINK THAT OPENS ON A CLICK AND IN A NEW TAB ON A DOUBLE-CLICK (2026-10-21,
  # fileopen_controller.js, mounted on the layout's <main>). Merged into a link's data the way
  # with_selection is: the action is APPENDED, never replaced, because the file menu and the
  # thumbnail poll share the hash. `new_tab:` is for a link whose href is NOT the file page — the
  # model page's list, whose click swaps the pane — and is omitted everywhere else, so the key is
  # absent rather than nil.
  def file_open_data(data = {}, new_tab: nil)
    opened = data.merge(action: [ data[:action], "click->fileopen#click" ].compact.join(" "))
    new_tab ? opened.merge(fileopen_new_tab_url: new_tab) : opened
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

  # The type dropdown's `<optgroup>`s: [[family label, [[ext, count], ...]], ...].
  #
  # `facets` is FilesController#ext_facets — what the LIBRARY holds. EXT_FAMILIES is only consulted
  # for GROUPING AND ORDER, never for membership, and that inversion is the whole change: the chip
  # row this replaced iterated the vocabulary and offered `.sldasm` to someone who has never owned
  # one, while an extension the user really did have appeared nowhere.
  #
  # ANYTHING THE VOCABULARY HAS NEVER HEARD OF LANDS IN "Other" RATHER THAN BEING DROPPED. That
  # bucket is the free-text escape hatch's replacement, and it is strictly better than the field
  # was: the user no longer has to know the extension, because it can only appear here if they
  # already have a file with it. (ROLE_LABELS' own "other" never collides — it is the fallback for
  # unrecognised extensions, so no extension maps to it and EXT_FAMILIES omits it entirely.)
  #
  # ACTIVE EXTENSIONS ARE EXCLUDED, because the dropdown ADDS and the chips beside it REMOVE.
  # Offering an active type would be an option whose selection changes nothing — `add_ext` unions
  # into `ext`, so re-adding is a no-op — which is the class of dead control this row has already
  # been fixed for twice.
  def ext_facet_groups(facets, active_exts)
    remaining = facets.except(*active_exts)
    known = EXT_FAMILIES.filter_map do |label, exts|
      entries = exts.select { |e| remaining.key?(e) }.sort.map { |e| [ e, remaining[e] ] }
      [ label, entries ] if entries.any?
    end
    other = (remaining.keys - EXT_FAMILIES.values.flatten).sort.map { |e| [ e, remaining[e] ] }
    other.any? ? known + [ [ "Other", other ] ] : known
  end

  # The URL for toggling `ext` into or out of the active set.
  #
  # NEITHER `folder` NOR `sort`/`dir` RIDES ALONG, and both omissions are the same argument
  # files_query_base makes about `view`. `folder` because activating a filter LEAVES the folder
  # (see #index), so carrying it would put a param in the URL that the request then ignores.
  # `sort`/`dir` because they are cookie-persisted: pinning them would freeze into a copied or
  # bookmarked chip URL a choice the user can still change from the headers.
  #
  # `q` DOES ride along, and it is the one param here that must: a search and a type filter compose
  # into ONE question (spec §9), so a chip that dropped the search would answer a different one --
  # turning ".stl among “lamp”" into "every .stl", with nothing on the page saying it had.
  def ext_toggle_path(ext, active_exts, q: nil)
    toggled = active_exts.include?(ext) ? active_exts - [ ext ] : active_exts + [ ext ]
    files_path({ ext: toggled.presence&.join(","), q: }.compact)
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

  # A KiCad schematic or board (stage 3, S3-2) — projects/_schematics.html.erb's own membership
  # test. Reads FilesController::KICANVAS_EXTS rather than a second copy of the two extensions, the
  # same way #ext_slots_left? above reads MAX_EXTS: one list, so the Schematics section and
  # FilesController#preview_kind's :kicanvas branch can never name a different set of formats.
  def kicad?(name)
    FilesController::KICANVAS_EXTS.include?(File.extname(name).downcase.delete("."))
  end

  # THE ONE WIRE SHAPE gerber_controller.js READS FOR A ZIPPED EXPORT — one entry, the zip's own
  # name and URL, `archive: true`, and the member paths the browser extracts with JSZip after
  # fetching the zip once through the same URL a download uses (Maker::GerberArchive's header).
  # Built here rather than as a literal in FilePreview#viewer_for (its one caller, for both file
  # pages) so that only a browser ever reads these keys and no second spelling of them exists for a
  # server-side assertion to miss drifting. Its loose-layer sibling is `FilePreview#gerber_layer_for`
  # (`{ name:, url: }`).
  def gerber_archive_entry(name:, url:, members:)
    { name:, url:, archive: true, members: }
  end

  # ONE number formatter for both recipe panels (laser and CNC), because they were each getting
  # it wrong in a different direction and neither could be caught by the fixtures.
  #
  # `.to_i` — what the laser panel used for speed and power — does not round, it TRUNCATES. A
  # layer cut at 6.67 mm/s displayed as "6 mm/s": not a formatting nit but a wrong setting shown
  # as though it were the real one, and the same class of error as reading a MillMage ToolDef
  # instead of its Operation. Every checked-in fixture uses whole speeds and powers, so the suite
  # could not see it.
  #
  # Printing the raw float instead is not the fix either: a metadata Hash holds 50.0 and 13.0, and
  # "50.0 mm/s" is noise in a table. So round — never truncate — then drop a trailing zero that
  # carries no information. THREE DECIMALS because that is what `MageMetadata#num` already rounds
  # tool values to (MillMage stores 1/8" as 3.1749999523162842), so the panel and the stored Hash
  # agree instead of the view inventing a second precision.
  #
  # Numeric strings are accepted because the Hash comes back out of a JSON column, and anything
  # that is not a number answers nil so a best-effort metadata gap renders as an empty cell rather
  # than the word "nil" beside a unit.
  RECIPE_DECIMALS = 3

  def recipe_num(value)
    return nil if value.nil?

    f = Float(value, exception: false)
    return nil if f.nil?

    r = f.round(RECIPE_DECIMALS)
    (r == r.to_i ? r.to_i : r).to_s
  end
end
