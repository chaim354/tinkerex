# WHERE THE STRIP'S ADD PUTS WHAT IT MAKES — its Upload, New folder, Text file and tools (structural
# redesign spec §8, slice 4; the strip since Shop manual slice 3): the folder the maker is looking at,
# set by the action that renders that folder and by nothing else.
#
# It replaced the global current project, and how it replaced it is the point: NOTHING HERE READS
# SESSION OR USER STATE. A page that shows a folder names it (FilesController#index and #show,
# ProjectsController#show, Tools::AddonsController#show, WelcomeController#files); a page that shows
# none leaves this nil, and Upload asks with the folder chooser (upload_pick_controller.js).
# test/architecture_invariants_test.rb forbids the retired names.
module FolderDestination
  extend ActiveSupport::Concern

  # `path` is root-relative with no leading slash ("Projects/shop-stool") and "" at the library root —
  # Maker::LibraryTree#path_for's spelling.
  #
  # IT CARRIES NO WEIGHT ANY MORE. It had a `primary` flag, and Recent an `upload_primary!`, while the
  # top bar's Upload was the Library's, Recent's and the hub's accent action; the strip's Add is an
  # outlined button on every page (Shop manual slice 3), so where a thing lands is all this says.
  Destination = Data.define(:node_id, :path) do
    def caption = path.presence || "the library root"
  end

  included do
    helper_method :folder_destination, :upload_return
  end

  private

  def folder_destination = @folder_destination

  # A Destination with a nil node_id means the library ROOT, not "ask": a page that shows no folder
  # sets none at all.
  def use_folder_destination(node_id, path:)
    @folder_destination = Destination.new(node_id:, path: path.to_s)
  end

  # WHERE A SUCCESSFUL UPLOAD FROM ADD GOES NEXT, on the one page that changes it: the onboarding
  # wizard's Files step (WelcomeController#files). `flag` is the allowlisted `return_to` the share/s3
  # form posts (FilesController#welcome_return_path reads it); `url` is the chunk uploader's
  # redirectUrl, which it follows after a clean run. nil on every other page, so
  # layouts/_strip_add renders exactly what it did before.
  UploadReturn = Data.define(:flag, :url)

  def upload_return = @upload_return
  def use_upload_return(flag, url:) = (@upload_return = UploadReturn.new(flag:, url:))
end
