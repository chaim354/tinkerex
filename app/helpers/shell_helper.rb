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
    "trash" => %w[trash]
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
    collapse: "M3 8h10 M7 4L3 8l4 4"
  }.freeze

  # An unknown or absent cookie is the default. The cookie is client-written (theme_controller.js)
  # and is never trusted for anything but this enum.
  def ui_theme
    value = cookies[:theme].to_s
    THEMES.include?(value) ? value : "dark"
  end

  def rail_collapsed? = cookies[:rail] == "collapsed"

  # `rail--collapsed` only inside the shell: its rules are descendant selectors (`.rail--collapsed
  # .brand-name`), and the auth card renders a `.brand` too — a user who collapsed the rail and
  # signed out landed on a sign-in card with its wordmark hidden (found in review, 2026-09-04).
  def body_classes
    signed_in = respond_to?(:user_signed_in?) && user_signed_in?
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
