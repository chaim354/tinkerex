# The application shell's server-side state (spec §5): which rail section this request belongs
# to, and the two cookies the layout renders into the first byte of HTML so there is no flash of
# the wrong theme and no inline script — the CSP nonces script-src (§14e), and a script that
# runs before paint is exactly the kind of thing not to add.
module ShellHelper
  THEMES = %w[dark light system].freeze

  # controller_path's FIRST segment, so projects/tasks, models/print_runs and tools/addons all
  # resolve to their family. A controller not listed here lights nothing, which is correct for
  # Devise's pages (they render without the rail anyway).
  SECTIONS = {
    "home" => %w[home],
    "files" => %w[files library_browse notes repo_commits repo_histories],
    "models" => %w[models shelves],
    "projects" => %w[projects current_project],
    "inventory" => %w[inventory_items suppliers locations],
    "tools" => %w[tools],
    "trash" => %w[trash],
    # The hub and its own children (settings/tags) light the rail FOOT's Settings link, not a rail
    # item; Shelves, Suppliers and Locations keep lighting the section they serve (models, inventory).
    "settings" => %w[settings]
  }.freeze

  ICON_PATHS = {
    home: "M2 8l6-5 6 5v6H9v-4H7v4H2z",
    files: "M2 4h5l2 2h5v7H2z",
    models: "M8 2l6 3v6l-6 3-6-3V5z M2 5l6 3 6-3 M8 8v6",
    projects: "M2 3h12v10H2z M6 3v10 M10 3v10",
    inventory: "M2 5h12v8H2z M2 5l2-3h8l2 3 M6 8h4",
    tools: "M10.5 2.5a3.5 3.5 0 0 0-3.2 4.9L2 12.7 3.3 14l5.3-5.3a3.5 3.5 0 0 0 4.9-3.2L11.6 7.4 9.6 6.4l1.9-1.9z",
    trash: "M3 4h10 M6 4V2.5h4V4 M4.5 4l.8 9.5h5.4L11.5 4 M7 7v4.5 M9 7v4.5",
    search: "M7 2.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9z M10.5 10.5L14 14",
    theme: "M8 2a6 6 0 0 0 0 12V2z M8 2a6 6 0 1 1 0 12",
    collapse: "M3 8h10 M7 4L3 8l4 4",
    settings: "M8 5a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M8 1.5v2 M8 12.5v2 M1.5 8h2 M12.5 8h2 M3.4 3.4l1.4 1.4 M11.2 11.2l1.4 1.4 M3.4 12.6l1.4-1.4 M11.2 4.8l1.4-1.4"
  }.freeze

  # An unknown or absent cookie is the default. The cookie is client-written (theme_controller.js)
  # and is never trusted for anything but this enum.
  def ui_theme
    value = cookies[:theme].to_s
    THEMES.include?(value) ? value : "dark"
  end

  def rail_collapsed? = cookies[:rail] == "collapsed"

  # IS THIS A PUBLIC SURFACE? `respond_to?` because a public controller stands on
  # ActionController::Base and Devise's own pages have neither helper. Extracted from
  # #shell_signed_in? (stage 4, S4-5) so the LAYOUT can ask it directly for the visitor's header
  # without a second copy of the `respond_to?` dance — and so the ORDER argument below stays in one
  # place. One definition, read by both, is what keeps the header and the shell from disagreeing
  # about which surface this is.
  def public_shell? = respond_to?(:public_surface?) && public_surface?

  # The signed-in shell (rail, tab bar, current-project switcher) renders for a signed-in user on
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

  # `rail--collapsed` only inside the shell: its rules are descendant selectors (`.rail--collapsed
  # .brand-name`), and the auth card renders a `.brand` too — a user who collapsed the rail and
  # signed out landed on a sign-in card with its wordmark hidden (found in review, 2026-09-04).
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

  def rail_links
    [
      [ "home", "Home", root_path, :home ],
      [ "files", "Files", files_path, :files ],
      [ "models", "Models", models_path, :models ],
      [ "projects", "Projects", projects_path, :projects ],
      [ "inventory", "Inventory", inventory_items_path, :inventory ],
      [ "tools", "Tools", tools_path, :tools ],
      [ "trash", "Trash", trash_index_path, :trash ]
    ]
  end

  def rail_icon(name)
    tag.svg(viewBox: "0 0 16 16", class: "rail-icon", "aria-hidden": "true") do
      tag.path(d: ICON_PATHS.fetch(name), fill: "none", stroke: "currentColor",
               "stroke-width": "1.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # The page's own name for the top bar when it supplies no breadcrumb: the title minus the
  # " — Tinkerex" suffix every page appends.
  def page_title_text
    content_for(:title).to_s.sub(/\s+[—-]\s+Tinkerex\z/, "").presence || "Tinkerex"
  end

  def theme_color_hex = ui_theme == "light" ? "#f4f5f7" : "#15181d"

  def color_scheme_meta
    case ui_theme
    when "light" then "light"
    when "system" then "light dark"
    else "dark"
    end
  end
end
