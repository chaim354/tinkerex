# What the strip's Add makes besides an upload — New folder, Text file, the tools (the top bar's
# New ▾ menu until Shop manual slice 3; structural redesign spec §4.2, slice 2). What it creates lands
# in the folder the maker is standing in. Slice 2 read that off `params[:folder]` on files#index alone
# and answered the library root everywhere else; slice 4 generalised it to FolderDestination — the
# VALIDATED folder, set by whichever action renders one (the Library, a file's workspace, a project
# hub, a tool page) — so Add creates exactly where its Upload saves. nil on a page that shows no
# folder, which the menu treats as the library root.
module NewMenuHelper
  def new_menu_folder_node_id = folder_destination&.node_id

  # The tool entries are NOT here: Tools::HomeController#new_menu serves them to a lazy frame when the
  # menu opens, so no page render reads the addon registry (docs/invariants/addons.md).
end
