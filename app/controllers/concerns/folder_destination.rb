# WHERE THE TOP BAR'S UPLOAD AND NEW ▾ MENU PUT WHAT THEY MAKE (structural redesign spec §8, slice 4):
# the folder the maker is looking at, set by the action that renders that folder and by nothing else.
#
# It replaced the global current project, and how it replaced it is the point: NOTHING HERE READS
# SESSION OR USER STATE. A page that shows a folder names it (FilesController#index and #show,
# ProjectsController#show, Tools::AddonsController#show); a page that shows none leaves this nil, and
# Upload asks with the folder chooser (upload_pick_controller.js). test/architecture_invariants_test.rb
# forbids the retired names.
module FolderDestination
  extend ActiveSupport::Concern

  # `path` is root-relative with no leading slash ("Projects/shop-stool") and "" at the library root —
  # Maker::LibraryTree#path_for's spelling. `primary` is whether Upload is this screen's accent action
  # (docs/invariants/design-system.md rule 13): the Library and the project hub, nowhere else.
  Destination = Data.define(:node_id, :path, :primary) do
    def caption = path.presence || "the library root"
  end

  included do
    helper_method :folder_destination
  end

  private

  def folder_destination = @folder_destination

  def use_folder_destination(node_id, path:, primary: false)
    @folder_destination = Destination.new(node_id:, path: path.to_s, primary:)
  end
end
