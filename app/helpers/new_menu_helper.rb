# The top bar's New ▾ menu (structural redesign spec §4.2, slice 2). What it creates lands in the
# folder the maker is standing in. In this slice that is the Files page's folder (`params[:folder]`
# on files#index) and the library root everywhere else; slice 4 generalises "the folder you're in"
# to every page and moves Upload into this bar beside it.
module NewMenuHelper
  def new_menu_folder_node_id
    params[:folder].presence if controller_path == "files" && action_name == "index"
  end

  # The tool entries are NOT here: Tools::HomeController#new_menu serves them to a lazy frame when the
  # menu opens, so no page render reads the addon registry (docs/invariants/addons.md).
end
