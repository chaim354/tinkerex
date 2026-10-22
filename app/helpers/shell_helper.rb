# The application shell's server-side state (spec §5): which rail section this request belongs
# to, and the two cookies the layout renders into the first byte of HTML so there is no flash of
# the wrong theme and no inline script — the CSP nonces script-src (§14e), and a script that
# runs before paint is exactly the kind of thing not to add.
module ShellHelper
  THEMES = %w[light dark system].freeze

  # controller_path's FIRST segment, so projects/tasks, models/print_runs and tools/addons all
  # resolve to their family. A controller not listed here lights nothing, which is correct for
  # Devise's pages (they render without the rail anyway).
  SECTIONS = {
    "home" => %w[home],
    "files" => %w[files library_browse notes repo_commits repo_histories],
    "models" => %w[models],
    "projects" => %w[projects],
    "inventory" => %w[inventory_items suppliers locations],
    "tools" => %w[tools],
    "trash" => %w[trash],
    # The hub and its own children (settings/tags, settings/shelves, settings/library) light the
    # rail FOOT's Settings link, not a rail item — through this one entry, because the key is the
    # controller path's first segment and every one of them is `settings/…`.
    #
    # SUPPLIERS AND LOCATIONS STILL LIGHT THE SECTION THEY SERVE — and since 2026-09-10 the URL
    # agrees, which is the whole point of that move. They lived at `/settings/*` while this map lit
    # Inventory, so clicking Settings landed a maker on a page where Settings went dark and something
    # else was highlighted: `/inventory/suppliers` and `/inventory/locations` now read like what they
    # are, and the old paths 301 (config/routes.rb) and must keep doing so.
    # /settings/shelves is the Shelves page (2026-10-20: the folders filed into inside each
    # project), a setting like its siblings, so `shelves` names no section of its own.
    "settings" => %w[settings],
    # /help lights the rail foot's Help, as the hub lights Settings: a page the rail links to must
    # not render with nothing lit (design-system.md rule 8).
    "help" => %w[help]
  }.freeze

  ICON_PATHS = {
    # A clock for Recent (slice 6), the root page's link in the sidebar and the tab bar. The page's
    # sidebar KEY is still [:home] (sidebar_current) — only the label and the drawing changed.
    recent: "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 5v3l2 1.5",
    files: "M2 4h5l2 2h5v7H2z",
    models: "M8 2l6 3v6l-6 3-6-3V5z M2 5l6 3 6-3 M8 8v6",
    projects: "M2 3h12v10H2z M6 3v10 M10 3v10",
    inventory: "M2 5h12v8H2z M2 5l2-3h8l2 3 M6 8h4",
    tools: "M10.5 2.5a3.5 3.5 0 0 0-3.2 4.9L2 12.7 3.3 14l5.3-5.3a3.5 3.5 0 0 0 4.9-3.2L11.6 7.4 9.6 6.4l1.9-1.9z",
    trash: "M3 4h10 M6 4V2.5h4V4 M4.5 4l.8 9.5h5.4L11.5 4 M7 7v4.5 M9 7v4.5",
    search: "M7 2.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9z M10.5 10.5L14 14",
    theme: "M8 2a6 6 0 0 0 0 12V2z M8 2a6 6 0 1 1 0 12",
    collapse: "M3 8h10 M7 4L3 8l4 4",
    settings: "M8 5a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M8 1.5v2 M8 12.5v2 M1.5 8h2 M12.5 8h2 M3.4 3.4l1.4 1.4 M11.2 11.2l1.4 1.4 M3.4 12.6l1.4-1.4 M11.2 4.8l1.4-1.4",
    # A door and an arrow leaving it, for the rail foot's Sign out (slice 7): collapsed, the foot
    # draws icons only, and a bare-text button wrapped "Sign out" onto two lines in a 40px column.
    sign_out: "M6 3H3v10h3 M10 5l3 3-3 3 M13 8H7",
    # A question mark in Recent's own circle, for the rail foot's Help (onboarding, 2026-10-13). The
    # hook is r1.6 and the dot sits a full pixel below the stem, so at 16px it reads as a "?" rather
    # than a blot; the dot is a .01 segment because a zero-length one draws nothing in some engines.
    help: "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2z M6.4 5.9a1.6 1.6 0 1 1 2.73 1.13c-.4.4-1.13.72-1.13 1.27v.35 M8 11.35v.01",
    # A page with a folded corner and two lines: a file's note-count badge (slice 7), which drew
    # the last emoji in the interface (test/no_emoji_test.rb). The count and its title stay.
    note: "M3 2h7l3 3v9H3z M5 7h6 M5 10h6",
    # A calculator: the body, its display, and two rows of keys drawn as dots (.01 segments, the help
    # icon's trick for a dot that draws in every engine). The rail's pinned Calculator link and the
    # Tools card (2026-10-21).
    calculator: "M4 1.5h8v13H4z M6 4h4v2.5H6z M6.25 9.5v.01 M8 9.5v.01 M9.75 9.5v.01 M6.25 12v.01 M8 12v.01 M9.75 12v.01"
  }.freeze

  # An unknown or absent cookie is the default, LIGHT ("Paper") since the 2026-10-08 redesign: the
  # library is mostly opaque white renders, and a paper page frames them where a dark one framed
  # white squares. The cookie is client-written (theme_controller.js) and is never trusted for
  # anything but this enum.
  def ui_theme
    value = cookies[:theme].to_s
    THEMES.include?(value) ? value : "light"
  end

  def rail_collapsed? = cookies[:rail] == "collapsed"

  # IS THIS A PUBLIC SURFACE? `respond_to?` because a public controller stands on
  # ActionController::Base and Devise's own pages have neither helper. Extracted from
  # #shell_signed_in? (stage 4, S4-5) so the LAYOUT can ask it directly for the visitor's header
  # without a second copy of the `respond_to?` dance — and so the ORDER argument below stays in one
  # place. One definition, read by both, is what keeps the header and the shell from disagreeing
  # about which surface this is.
  def public_shell? = respond_to?(:public_surface?) && public_surface?

  # The signed-in shell (rail, tab bar) renders for a signed-in user on
  # every page EXCEPT a public one, which renders what a visitor sees (Public::BaseController, stage
  # 3, S3-4). `respond_to?` on both halves because a public controller stands on
  # ActionController::Base and has neither helper — and Devise's own pages have no
  # `public_surface?`.
  # THE PUBLIC CHECK COMES FIRST, AND THE ORDER IS LOAD-BEARING RATHER THAN A STYLE CHOICE:
  # `user_signed_in?` is Warden's, so asking it AT ALL reads the session cookie and resolves a
  # user — which is precisely what a public request must not do. Short-circuiting on
  # `public_surface?` means a visitor's request never touches Warden; the boolean result is
  # identical either way, so nothing but the invariant tells the two orders apart.
  def shell_signed_in?
    return false if public_shell?

    respond_to?(:user_signed_in?) && user_signed_in?
  end

  # `rail--collapsed` only inside the shell, where it sets the rail's grid TRACK and nothing else
  # (`body.app-shell.rail--collapsed`, shell.css). The icon rail itself is a container query on
  # `.rail`, so no rule keyed on this class reaches the `.brand` the auth card renders. Until F-S20-1
  # its rules were descendant selectors (`.rail--collapsed .brand-name`), and a user who collapsed
  # the rail and signed out landed on a sign-in card with its wordmark hidden (found in review,
  # 2026-09-04).
  #
  # READS `shell_signed_in?`, NOT `user_signed_in?`, FOR THE SAME REASON THE LAYOUT DOES.
  # `body.app-shell` is a two-column grid whose first column is the rail's width (shell.css); a
  # signed-in owner previewing their own public page renders NO rail, so the class alone would
  # leave an empty rail-wide column and push the whole page off-centre — and at 375px it is what
  # the phone sweep's `scrollWidth <= innerWidth` assertion would catch.
  def body_classes
    signed_in = shell_signed_in?
    classes = []
    classes << "app-shell" if signed_in
    classes << "rail--collapsed" if signed_in && rail_collapsed?
    classes.join(" ")
  end

  def rail_section
    head = controller_path.split("/").first
    SECTIONS.find { |_key, heads| heads.include?(head) }&.first
  end

  # --- The places sidebar (structural redesign spec §4.1, slice 2). Each list is ONE query
  # whatever it holds, so no page's query count grows with projects or pins
  # (page_query_budget_test.rb). Memoised per request: the sidebar and the tab bar both read them.
  SIDEBAR_PROJECTS = 8

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

  # Inventory earns its sidebar entry once it is used — or while the maker is standing in it, so the
  # page they are on is never one with no lit link.
  def sidebar_inventory?
    rail_section == "inventory" || current_user.maker_inventory_items.exists?
  end

  # THE ONE ANSWER TO "WHICH LINK IS LIT", so exactly one is. A key, compared by sidebar_aria:
  #   [:home] [:library] [:pin, node_id] [:project, id] [:all_projects] [:models] [:inventory]
  #   [:tools] [:tool, key] [:trash] [:settings] [:help]
  # The Library's 3D models view (`files/models`) lights [:models], not Library, though its section
  # is files (slice 5).
  # On the Files page AND a file's own page the DEEPEST pinned folder on the breadcrumb wins over
  # Library (`@crumbs` is the folder chain FilesController#index and #show both build; absent
  # elsewhere, where Library lights). On a project page the project's own
  # link wins, unless it is older than the eight listed — then All projects, never nothing.
  def sidebar_current
    @sidebar_current ||=
      case rail_section
      when "home" then [ :home ]
      when "files"
        # The Library's 3D models VIEW lights its own place, not Library (slice 5). Only one link is lit.
        if controller_path == "files/models"
          [ :models ]
        else
          pinned = sidebar_pins.map { |pin, _| pin.node_id }
          deepest = Array(@crumbs).map(&:node_id).reverse.find { |id| pinned.include?(id) }
          deepest ? [ :pin, deepest ] : [ :library ]
        end
      when "projects"
        id = @project&.id
        id && sidebar_projects.any? { |p| p.id == id } ? [ :project, id ] : [ :all_projects ]
      when "models" then [ :models ]
      when "inventory" then [ :inventory ]
      when "tools"
        # A PINNED ADDON'S OWN PAGE LIGHTS ITS PINNED LINK, as a pinned folder beats Library. The
        # calculator never lights: it is a modal over the page, not a page.
        key = params[:key].to_s if controller_path == "tools/addons"
        key && key != Maker::ToolPins::CALCULATOR && current_user.tool_pins.pinned?(key) ? [ :tool, key ] : [ :tools ]
      when "trash" then [ :trash ]
      when "settings" then [ :settings ]
      when "help" then [ :help ]
      end
  end

  def sidebar_aria(key) = sidebar_current == key ? "page" : nil

  # THE RIGHT-CLICK MENU ON A TOOL (toolmenu_controller.js): the card in the Tools gallery, or the
  # tool's pinned link in the rail. The server writes the URL and the state, so the menu says what a
  # click DOES ("Pin to sidebar" / "Unpin from sidebar") and never assembles a path. Merged into a
  # link's own `data:` by the caller, which is why `extra` exists (the calculator's opener).
  def tool_menu_data(key, label, extra = {})
    pinned = current_user.tool_pins.pinned?(key)
    { action: "contextmenu->toolmenu#open", tool_pin_url: tools_pin_path(key), tool_pinned: pinned.to_s,
      tool_name: label }.merge(extra)
  end

  # COLLAPSED — and below 1100px whatever the cookie says — project, pin and pinned-addon links hide
  # with their labels (shell.css), so a lit one would leave the rail with nothing lit to see. Its
  # family link carries the mark there instead: Library for a pin, All projects for a project, Tools
  # for a pinned addon (they all wear the Tools glyph, so icons alone could not tell them apart). A CLASS, never
  # aria-current, so the markup still lights exactly one link; shell.css draws it only when narrow.
  def sidebar_family_lit?(family) = { pin: :library, project: :all_projects, tool: :tools }[sidebar_current&.first] == family

  # The phone tab bar: four destinations, each lit by the same answer the sidebar uses.
  def tabbar_links
    current = sidebar_current&.first
    [
      # Recent, the root page (slice 6): labelled and drawn as Recent, lit by the [:home] key.
      [ "Recent", root_path, :recent, current == :home ],
      # The 3D models view is a Library view; the bar has no place of its own for it. The same key
      # lights the model pages ModelsController still serves.
      [ "Library", files_path, :files, %i[library pin models].include?(current) ],
      [ "Projects", projects_path, :projects, %i[project all_projects].include?(current) ],
      [ "Tools", tools_path, :tools, %i[tools tool].include?(current) ]
    ]
  end

  def rail_icon(name)
    tag.svg(viewBox: "0 0 16 16", class: "rail-icon", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(name), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # The folder glyph on tiles, list rows, the trash and the folder field: the rail's own `files`
  # path, so a folder looks the same in the nav and in the grid (design system: no emoji in the
  # interface; the 📁 it replaces rendered differently on every OS).
  def folder_glyph
    tag.svg(viewBox: "0 0 16 16", class: "folder-glyph", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(:files), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # The page's own name for the top bar when it supplies no breadcrumb: the title minus the
  # " — Tinkerex" suffix every page appends.
  def page_title_text
    content_for(:title).to_s.sub(/\s+[—-]\s+Tinkerex\z/, "").presence || "Tinkerex"
  end

  # The browser chrome's colour: Graphite's ground for dark, Paper's for light AND for system,
  # because the server cannot see the OS setting and light is the default.
  def theme_color_hex = ui_theme == "dark" ? "#141512" : "#f4f2ed"

  def color_scheme_meta
    case ui_theme
    when "dark" then "dark"
    when "system" then "light dark"
    else "light"
    end
  end
end
