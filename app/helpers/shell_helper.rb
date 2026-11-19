# The application shell's server-side state (Shop manual spec §7, slice 3): which of the four places
# and which left-column row this request lights, what the column lists, and the theme cookie the
# layout renders into the first byte of HTML so there is no flash of the wrong theme and no inline
# script — the CSP nonces script-src (§14e), and a script that runs before paint is exactly the kind
# of thing not to add (design-system.md rule 7).
module ShellHelper
  THEMES = %w[light dark system].freeze

  # controller_path's FIRST segment, so projects/tasks, models/print_runs and tools/addons all
  # resolve to their family — or, for an entry holding a "/", the WHOLE controller path, so one
  # controller can join a section its first segment does not name (users/registrations below). A
  # controller not listed here lights nothing and gets no default column, which is correct for
  # Devise's signed-out pages (they render without the shell anyway) and for Search, which lights
  # no place (spec §11.2).
  SECTIONS = {
    # The onboarding wizard (2026-11-09) opens from Home, so it is Home's: it lights no place either.
    "home" => %w[home welcome],
    "files" => %w[files library_browse notes repo_commits repo_histories],
    "models" => %w[models],
    "projects" => %w[projects],
    # SUPPLIERS AND LOCATIONS LIGHT THE PLACE THEY SERVE, and since 2026-09-10 the URL agrees:
    # `/inventory/suppliers` and `/inventory/locations` (the old `/settings/*` paths 301,
    # config/routes.rb, and must keep doing so).
    "inventory" => %w[inventory_items suppliers locations],
    "tools" => %w[tools],
    "trash" => %w[trash],
    # The hub and its own children (settings/tags, settings/shelves, settings/library, …) are one
    # section through this one entry, because every one of them is `settings/…`. /settings/shelves
    # is the Shelves page (2026-10-20), a setting like its siblings.
    #
    # THE ACCOUNT PAGE (Devise's registrations#edit, /users/edit) IS A SETTINGS PAGE: the hub links
    # to it (UX audit F1). By its whole path, not `users`: the other users/* controllers are
    # Devise's signed-out doors, which have no shell.
    "settings" => %w[settings users/registrations],
    "help" => %w[help]
  }.freeze

  # THE FOUR PLACES, IN THE STRIP'S ORDER (spec §3): always all four, on every signed-in page, and in
  # the phone tab bar below 720px. Each lights for the row keys listed here, so the place is DERIVED
  # from `sidebar_current`'s one key and never decided a second time. A key no place lists (Home,
  # Settings, Help) lights no place (spec §11.2): Home is the wordmark's, and the account menu holds
  # Settings and Help.
  PLACES = {
    library: { label: "Library", icon: :files, keys: %i[library folder models trash] },
    projects: { label: "Projects", icon: :projects, keys: %i[all_projects archived_projects project_kind project new_project] },
    tools: { label: "Tools", icon: :tools, keys: %i[tools tool] },
    inventory: { label: "Inventory", icon: :inventory, keys: %i[inventory inventory_items low_stock location locations supplier suppliers] }
  }.freeze

  # WHICH DEFAULT COLUMN A SECTION GETS (spec §7's table) when its page supplies none through
  # `content_for :column`: layouts/column/_<name>. The 3D models view, the model pages and Trash
  # are Library pages, so they get the Library's.
  COLUMNS = {
    "home" => "home", "files" => "library", "models" => "library", "trash" => "library",
    "projects" => "projects", "inventory" => "inventory", "tools" => "tools",
    "settings" => "settings", "help" => "help"
  }.freeze

  # The Settings column's rows, by the controller that renders each page. A settings controller not
  # named here (a redirect-only door) lights the section's key with no row.
  SETTINGS_ROWS = {
    "settings" => :hub, "settings/library" => :library, "settings/shelves" => :shelves,
    "settings/tags" => :tags, "settings/users" => :users, "settings/devices" => :devices,
    "users/registrations" => :account
  }.freeze

  ICON_PATHS = {
    files: "M2 4h5l2 2h5v7H2z",
    models: "M8 2l6 3v6l-6 3-6-3V5z M2 5l6 3 6-3 M8 8v6",
    projects: "M2 3h12v10H2z M6 3v10 M10 3v10",
    inventory: "M2 5h12v8H2z M2 5l2-3h8l2 3 M6 8h4",
    tools: "M10.5 2.5a3.5 3.5 0 0 0-3.2 4.9L2 12.7 3.3 14l5.3-5.3a3.5 3.5 0 0 0 4.9-3.2L11.6 7.4 9.6 6.4l1.9-1.9z",
    trash: "M3 4h10 M6 4V2.5h4V4 M4.5 4l.8 9.5h5.4L11.5 4 M7 7v4.5 M9 7v4.5",
    search: "M7 2.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9z M10.5 10.5L14 14",
    settings: "M8 5a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M8 1.5v2 M8 12.5v2 M1.5 8h2 M12.5 8h2 M3.4 3.4l1.4 1.4 M11.2 11.2l1.4 1.4 M3.4 12.6l1.4-1.4 M11.2 4.8l1.4-1.4",
    # A door and an arrow leaving it: the account menu's Sign out.
    sign_out: "M6 3H3v10h3 M10 5l3 3-3 3 M13 8H7",
    # A question mark in a circle: the account menu's Help. The hook is r1.6 and the dot sits a full
    # pixel below the stem, so at 16px it reads as a "?" rather than a blot; the dot is a .01 segment
    # because a zero-length one draws nothing in some engines.
    help: "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2z M6.4 5.9a1.6 1.6 0 1 1 2.73 1.13c-.4.4-1.13.72-1.13 1.27v.35 M8 11.35v.01",
    # A page with a folded corner and two lines: a file's note-count badge (slice 7), which drew
    # the last emoji in the interface (test/no_emoji_test.rb). The count and its title stay.
    note: "M3 2h7l3 3v9H3z M5 7h6 M5 10h6",
    # A calculator: the body, its display, and two rows of keys drawn as dots (.01 segments, the help
    # icon's trick for a dot that draws in every engine). The pinned Calculator row and the Tools
    # card (2026-10-21).
    calculator: "M4 1.5h8v13H4z M6 4h4v2.5H6z M6.25 9.5v.01 M8 9.5v.01 M9.75 9.5v.01 M6.25 12v.01 M8 12v.01 M9.75 12v.01",
    # A person, for the account menu's Account item: a head and shoulders.
    account: "M8 2.5a2.75 2.75 0 1 0 0 5.5 2.75 2.75 0 0 0 0-5.5z M2.5 14c.6-2.9 2.8-4.5 5.5-4.5s4.9 1.6 5.5 4.5",
    # A plus, for the strip's Add.
    plus: "M8 3v10 M3 8h10",
    # Three lines of uneven length, a table of contents: the strip's Contents button below 960px,
    # which opens the left column as a sheet.
    contents: "M2.5 4h11 M2.5 8h8 M2.5 12h11"
  }.freeze

  # An unknown or absent cookie is the default, LIGHT ("Paper") since the 2026-10-08 redesign: the
  # library is mostly opaque white renders, and a paper page frames them where a dark one framed
  # white squares. The cookie is client-written (theme_controller.js) and is never trusted for
  # anything but this enum.
  def ui_theme
    value = cookies[:theme].to_s
    THEMES.include?(value) ? value : "light"
  end

  # IS THIS A PUBLIC SURFACE? `respond_to?` because a public controller stands on
  # ActionController::Base and Devise's own pages have neither helper. Extracted from
  # #shell_signed_in? (stage 4, S4-5) so the LAYOUT can ask it directly for the visitor's header
  # without a second copy of the `respond_to?` dance — and so the ORDER argument below stays in one
  # place. One definition, read by both, is what keeps the header and the shell from disagreeing
  # about which surface this is.
  def public_shell? = respond_to?(:public_surface?) && public_surface?

  # The signed-in shell (strip, column, tab bar) renders for a signed-in user on every page EXCEPT a
  # public one, which renders what a visitor sees (Public::BaseController, stage 3, S3-4).
  # `respond_to?` on both halves because a public controller stands on ActionController::Base and
  # has neither helper — and Devise's own pages have no `public_surface?`.
  # THE PUBLIC CHECK COMES FIRST, AND THE ORDER IS LOAD-BEARING RATHER THAN A STYLE CHOICE:
  # `user_signed_in?` is Warden's, so asking it AT ALL reads the session cookie and resolves a
  # user — which is precisely what a public request must not do. Short-circuiting on
  # `public_surface?` means a visitor's request never touches Warden; the boolean result is
  # identical either way, so nothing but the invariant tells the two orders apart.
  def shell_signed_in?
    return false if public_shell?

    respond_to?(:user_signed_in?) && user_signed_in?
  end

  # READS `shell_signed_in?`, NOT `user_signed_in?`, FOR THE SAME REASON THE LAYOUT DOES: a
  # signed-in owner previewing their own public page renders no shell, so the class would style a
  # page that has none.
  def body_classes = shell_signed_in? ? "app-shell" : ""

  def shell_section
    head = controller_path.split("/").first
    SECTIONS.find { |_key, heads| heads.include?(head) || heads.include?(controller_path) }&.first
  end

  # --- What the column lists. Each list is ONE query whatever it holds, so no page's query count
  # grows with projects, pins, folders, places or suppliers (page_query_budget_test.rb). Memoised per
  # request: the column and `sidebar_current` both ask.
  SIDEBAR_PROJECTS = 8
  COLUMN_FOLDERS = 40
  COLUMN_PLACES = 30

  def sidebar_projects
    @sidebar_projects ||= current_user.maker_projects.where.not(status: "archived")
                                      .order(updated_at: :desc).limit(SIDEBAR_PROJECTS).to_a
  end

  # [pin, folder name] for each pin whose folder is LIVE, in pinned order. A tombstoned folder's pin
  # is skipped here and kept in the table, so restoring the folder restores the pin (Maker::Pin).
  def sidebar_pins
    @sidebar_pins ||= begin
      pins = current_user.maker_pins.ordered.to_a
      names = current_user.nodes.present.where(node_id: pins.map(&:node_id), kind: "dir")
                          .pluck(:node_id, :name).to_h
      pins.filter_map { |pin| [ pin, names[pin.node_id] ] if names.key?(pin.node_id) }
    end
  end

  # THE LIBRARY COLUMN'S FOLDERS (spec §7): the library root, the chain down to the folder this page
  # shows, then that folder's own subfolders, as [node_id (nil for the root), name, depth]. The chain
  # is `@crumbs`, which FilesController#index and #show already built for the breadcrumb, so it costs
  # nothing here; the subfolders are ONE query, capped, and the column says when it cut the list
  # (`column_folders_more?`). The full tree, remembering what is open, is a later behaviour (spec §9).
  # The same rows the Library lists: live, visible (no dot-folders, no `.git`, §14b).
  def column_folders
    @column_folders ||= begin
      chain = Array(@crumbs)
      parent_id = chain.last&.node_id
      children = current_user.nodes.present.visible_entries(false)
                             .where(kind: "dir", parent_node_id: parent_id)
                             .order(Arel.sql("LOWER(nodes.name)"), :node_id)
                             .limit(COLUMN_FOLDERS + 1).pluck(:node_id, :name)
      @column_folders_more = children.size > COLUMN_FOLDERS
      [ [ nil, "Library", 0 ] ] +
        chain.each_with_index.map { |crumb, i| [ crumb.node_id, crumb.name, i + 1 ] } +
        children.first(COLUMN_FOLDERS).map { |node_id, name| [ node_id, name, chain.size + 1 ] }
    end
  end

  def column_folders_more?
    column_folders
    @column_folders_more
  end

  # The Inventory column's Places and Suppliers: one query each, capped, by name.
  def column_locations
    @column_locations ||= current_user.maker_locations.order(Arel.sql("LOWER(name)"), :id).limit(COLUMN_PLACES).to_a
  end

  def column_suppliers
    @column_suppliers ||= current_user.maker_suppliers.order(Arel.sql("LOWER(name)"), :id).limit(COLUMN_PLACES).to_a
  end

  # THE ONE ANSWER TO "WHAT IS LIT", so at most one place and at most one column row are
  # (design-system.md rule 8; shell_layout_test.rb walks every page). A key, compared by `row_aria`;
  # the place is derived from it (PLACES), never decided twice:
  #   [:home] [:library] [:folder, node_id] [:models] [:trash]
  #   [:all_projects] [:archived_projects] [:project_kind, kind] [:project, id] [:new_project]
  #   [:tools] [:tool, key]
  #   [:inventory] [:inventory_items] [:low_stock] [:location, id] [:locations] [:supplier, id] [:suppliers]
  #   [:settings, row] [:help]
  # A key with no row on the page (Home's, Help's, an inventory item's) lights no row; that is
  # allowed, and two is not.
  #
  # IN THE LIBRARY the folder this page shows is the row: the deepest crumb (`@crumbs`, the chain
  # FilesController#index and #show both build; on a file's page its folder), else the library root.
  # The 3D models view (`files/models`), the model pages and Trash are Library pages and light their
  # own rows under Library (spec §11.2; this reversed rule 8's old exception, under which the 3D
  # models view lit a place of its own).
  def sidebar_current
    return @sidebar_current if defined?(@sidebar_current)

    @sidebar_current =
      case shell_section
      when "home" then [ :home ]
      when "files"
        if controller_path == "files/models"
          [ :models ]
        else
          folder = Array(@crumbs).last
          folder ? [ :folder, folder.node_id ] : [ :library ]
        end
      when "models" then [ :models ]
      when "trash" then [ :trash ]
      when "projects" then projects_current
      when "inventory" then inventory_current
      when "tools"
        # An addon's own page lights its row (the Tools column lists the pinned ones). The calculator
        # never lights: it is a modal over the page, not a page.
        key = params[:key].to_s if controller_path == "tools/addons"
        key.present? && key != Maker::ToolPins::CALCULATOR ? [ :tool, key ] : [ :tools ]
      when "settings" then [ :settings, SETTINGS_ROWS[controller_path] ]
      when "help" then [ :help ]
      end
  end

  # The place this request lights, or nil (Home, Search, Settings, Help).
  def sidebar_place
    key = sidebar_current&.first
    PLACES.find { |_place, spec| spec[:keys].include?(key) }&.first
  end

  def place_aria(place) = sidebar_place == place ? "page" : nil

  def row_aria(key) = sidebar_current == key ? "page" : nil

  # [place, label, path, icon] for the strip and the tab bar, in order.
  def strip_places
    paths = { library: files_path, projects: projects_path, tools: tools_path, inventory: inventory_items_path }
    PLACES.map { |place, spec| [ place, spec[:label], paths.fetch(place), spec[:icon] ] }
  end

  # ONE COLUMN ROW: a link, its name, an optional muted note at the right (a count, or what kind of
  # thing a pin is), lit when `key` is `sidebar_current`. `depth` indents a folder under its parent,
  # 16px a level, through a custom property shell.css reads. Extra options (data, title, aria) pass
  # through to the link, merged under the row's own class.
  def column_row(label, path, key: nil, note: nil, depth: 0, **options)
    classes = class_names("column-row", options.delete(:class))
    style = "--depth: #{depth}" if depth.positive?
    link_to path, class: classes, style:, "aria-current": (key && row_aria(key)), **options do
      safe_join([ tag.span(label, class: "column-row-name"), (tag.span(note, class: "column-row-note") if note) ].compact)
    end
  end

  # THE RIGHT-CLICK MENU ON A TOOL (toolmenu_controller.js): the card in the Tools gallery, or the
  # tool's pinned row in the column. The server writes the URL and the state, so the menu says what a
  # click DOES ("Pin to sidebar" / "Unpin from sidebar") and never assembles a path. Merged into a
  # link's own `data:` by the caller, which is why `extra` exists (the calculator's opener).
  def tool_menu_data(key, label, extra = {})
    pinned = current_user.tool_pins.pinned?(key)
    { action: "contextmenu->toolmenu#open", tool_pin_url: tools_pin_path(key), tool_pinned: pinned.to_s,
      tool_name: label }.merge(extra)
  end

  # The round account button's letter: the first letter or digit of the address, a middle dot for an
  # address with none (the interface draws no emoji, design-system.md rule 13).
  def account_initial = current_user.email.to_s[/[[:alnum:]]/]&.upcase || "·"

  # THE SEARCH SHORTCUTS (spec §11.5): `/` from anywhere not taking typing, and Ctrl/Cmd-K from
  # anywhere, both focusing the strip's box (shell_controller.js). The box's hint shows `/`; its title
  # names the chord per platform (⌘K on a Mac, iPhone or iPad, Ctrl+K elsewhere, UX audit A7), read
  # from the user agent the way CalculationsHelper#calculator_shortcut reads it. The controller
  # listens for both chords, so a user agent read wrongly costs a word, never the shortcut;
  # `aria-keyshortcuts` names all three, platform-neutrally.
  SEARCH_KEYS = "/ Control+K Meta+K".freeze

  def search_shortcut
    request.user_agent.to_s.match?(/Macintosh|iPhone|iPad/) ? "⌘K" : "Ctrl+K"
  end

  # THE APP'S LINE GLYPHS, 16px in a 16px box. The name is the rail's, which this helper drew first;
  # pages draw it too (`.rail-icon` is their class for it), so it keeps the name.
  def rail_icon(name)
    tag.svg(viewBox: "0 0 16 16", class: "rail-icon", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(name), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # The folder glyph on tiles, list rows, the trash and the folder field: the `files` path, so a
  # folder looks the same in the Library's place and in the grid (design system: no emoji in the
  # interface; the 📁 it replaces rendered differently on every OS).
  def folder_glyph
    tag.svg(viewBox: "0 0 16 16", class: "folder-glyph", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(:files), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # The page's own name for the page head's caps path when it supplies no breadcrumb: the title
  # minus the " — Tinkerex" suffix every page appends.
  def page_title_text
    content_for(:title).to_s.sub(/\s+[—-]\s+Tinkerex\z/, "").presence || "Tinkerex"
  end

  # The browser chrome's colour: Graphite's ground for dark, Paper's for light AND for system,
  # because the server cannot see the OS setting and light is the default.
  def theme_color_hex = ui_theme == "dark" ? "#111316" : "#ffffff"

  def color_scheme_meta
    case ui_theme
    when "dark" then "dark"
    when "system" then "light dark"
    else "light"
    end
  end

  private

  # THE PROJECTS COLUMN HAS TWO SHAPES, and the key follows the one on screen: on the index, the
  # filters the index already understands (All, Archived, a kind); on any other projects page, the
  # projects themselves. A listed project's own row beats All projects, and one older than the eight
  # listed lights All projects; New project lights on its own form.
  def projects_current
    if controller_path == "projects" && action_name == "index"
      kind = params[:kind].presence_in(Maker::Project::KINDS) if params[:kind].is_a?(String)
      return [ :project_kind, kind ] if kind

      return params[:archived] == "1" ? [ :archived_projects ] : [ :all_projects ]
    end
    return [ :new_project ] if controller_path == "projects" && %w[new create].include?(action_name)

    id = @project&.id
    id && sidebar_projects.any? { |p| p.id == id } ? [ :project, id ] : [ :all_projects ]
  end

  # The Inventory column's rows: the index and its two facets the column carries (low stock, a place,
  # a supplier — the same `?low=`, `?location=`, `?supplier=` the index already reads), and the
  # Places and Suppliers pages. An item's own pages light the place and no row.
  def inventory_current
    case controller_path
    when "suppliers" then [ :suppliers ]
    when "locations" then [ :locations ]
    else
      return [ :inventory ] unless action_name == "index"

      supplier = params[:supplier] if params[:supplier].is_a?(String)
      location = params[:location] if params[:location].is_a?(String)
      if supplier.present? then [ :supplier, supplier ]
      elsif location.present? then [ :location, location ]
      elsif params[:low] == "1" then [ :low_stock ]
      else [ :inventory_items ]
      end
    end
  end
end
