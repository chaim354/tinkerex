# The top bar's New ▾ menu (structural redesign spec §4.2, slice 2). What it creates lands in the
# folder the maker is standing in. In this slice that is the Files page's folder (`params[:folder]`
# on files#index) and the library root everywhere else; slice 4 generalises "the folder you're in"
# to every page and moves Upload into this bar beside it.
module NewMenuHelper
  def new_menu_folder_node_id
    params[:folder].presence if controller_path == "files" && action_name == "index"
  end

  # Available tools only; an unavailable one would be a menu entry that opens an apology. NOT ASKED
  # WITHOUT A SOURCE: an unconfigured Source.current raises KeyError, which Registry rescues to []
  # with a warning — on every page, since this is the layout.
  def new_menu_tools
    @new_menu_tools ||=
      Maker::Addons::Source.configured? ? Maker::Addons::Registry.all.select(&:available?) : []
  end
end
