module Files
  # "USE THIS VIEW AS PREVIEW" (2026-10-20). The 3D viewer renders the angle the maker chose as a
  # 512px PNG and posts it here; it becomes the file's thumbnail (Maker::Preview, source
  # "viewer") until the file's content changes, because Maker::Previews::Enqueue treats a viewer
  # row whose content token still matches as current. Session auth (§14d).
  #
  # THE PNG PASSES THROUGH RAILS, AND §15 PERMITS IT: §15 keeps LIBRARY bytes out of Rails; a
  # preview is app-owned derived data in Active Storage, the same thing POST /v1/maker/previews
  # already accepts from a device.
  #
  # THE ROW IS WRITTEN `ready`, NEVER IN FLIGHT. `Enqueue.needs_job?` answers false for a viewer
  # row at current content before it reaches its stall check, so a viewer row left `pending` or
  # `processing` would be believed forever with no job coming to settle it.
  class PreviewsController < ApplicationController
    MAX_BYTES = 2.megabytes
    MAX_SIDE = 1024
    PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze

    # FilesController's mapping, for the same two conditions: a node that is not this user's live
    # file, and one whose bytes vanished between the row and the stat, are one answer to a browser.
    rescue_from ActiveRecord::RecordNotFound, FileLayer::NotFound do
      respond_to do |format|
        format.html { redirect_to files_path, alert: "File not found." }
        format.any  { head :not_found }
      end
    end

    # POST /files/:node_id/preview { image } -- the viewer's PNG.
    def create
      node = live_file!
      upload = params[:image]
      return refuse("Choose an image to use as the preview.") unless upload.respond_to?(:read)
      return refuse("The preview image is too large.") if upload.size > MAX_BYTES

      bytes = upload.read.b
      width, height = png_size(bytes)
      return refuse("The preview must be a PNG image.") if width.nil?
      return refuse("The preview image is too large.") if width > MAX_SIDE || height > MAX_SIDE

      token = FileLayer.current.stat(current_user, node_id: node.node_id).content_token
      preview = current_user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
      preview.assign_attributes(
        source: "viewer", status: "ready", version_id: token, width:, height:, error: nil,
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail")
      )
      preview.asset.attach(io: StringIO.new(bytes), filename: "thumbnail-viewer-#{preview.node_id}.png",
                           content_type: "image/png")
      preview.save!

      respond_to do |f|
        f.json { render json: { url: url_for(preview.asset) }, status: :created }
        f.html { redirect_to file_path(node.node_id), notice: "Preview saved." }
      end
    rescue FileLayer::FetchError
      refuse("The library isn't reachable right now. Try again in a moment.", status: :service_unavailable)
    end

    # DELETE /files/:node_id/preview -- BACK TO THE RENDERER. `rebuilding`, not `pending`: the
    # maker's picture stays up until the render lands (Maker::Preview's `rebuilding` contract), then
    # the job replaces it. The revision is restamped to this build's, so the render that lands is
    # current at once rather than one renderer bump behind the picture it replaces.
    def destroy
      node = live_file!
      preview = current_user.maker_previews.find_by(node_id: node.node_id, kind: "thumbnail")
      if preview&.viewer?
        preview.update!(source: "renderer", status: "rebuilding",
                        renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail"))
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: node.name)
      end
      redirect_to file_path(node.node_id), notice: "Back to the automatic preview."
    end

    private

    # SCOPED THROUGH current_user: a foreign or tombstoned node_id is a 404, never another
    # user's row.
    def live_file! = current_user.nodes.present.find_by!(node_id: params.require(:node_id), kind: "file")

    # [width, height] from the IHDR chunk, or nil when this is not a PNG. The length check comes
    # first: a body holding the signature and nothing after it would otherwise unpack nils into the
    # size comparison and answer 500 instead of 422.
    def png_size(bytes)
      return nil unless bytes.bytesize >= 24
      return nil unless bytes.byteslice(0, 8) == PNG_MAGIC && bytes.byteslice(12, 4) == "IHDR"

      bytes.byteslice(16, 8).unpack("NN")
    end

    def refuse(message, status: :unprocessable_entity)
      respond_to do |f|
        f.json { render json: { error: message }, status: }
        f.html { redirect_to file_path(params[:node_id]), alert: message }
      end
    end
  end
end
