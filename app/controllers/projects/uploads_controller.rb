module Projects
  # Inline "upload a new file and attach it", for the WRITABLE backends (share/s3): the bytes come
  # up in ONE multipart POST and go straight to the port — the same single FileLayer.current.write
  # FilesController#create makes, plus an attach. No chunk path here: chunk mode's inline upload is
  # the browser two-phase flow (uploader_controller.js) which lands the node via /files/{begin,
  # finalize}_upload, then POSTs the node_id to the attach endpoint. So this never reaches into the
  # sync engine (spec §10) — it is the SAME write door FilesController already uses on these
  # backends. One controller serves both a project target and a build-log-entry target.
  class UploadsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_port_writable!

    def create
      file = params.require(:file)
      target = attach_target
      info = FileLayer.current.write(current_user, parent_node_id: nil,
                                     name: file.original_filename, io: file)
      enqueue_preview(node_id: info.node_id, name: file.original_filename)
      target.file_attachments.create!(user: current_user, node_id: info.node_id,
                                      role: role_for(file.original_filename, target))
      redirect_to project_path(project_of(target)), notice: "Uploaded #{file.original_filename}."
    end

    private

    # Exactly one of the two nested routes supplies the target.
    def attach_target
      if params[:build_log_entry_id].present?
        current_user.maker_build_log_entries.find(params[:build_log_entry_id])
      else
        current_user.maker_projects.find_by!(slug: params[:project_id])
      end
    end

    def project_of(target) = target.is_a?(Maker::BuildLogEntry) ? target.project : target

    # A build-log photo is always "image"; a project attachment infers from the extension.
    def role_for(name, target)
      target.is_a?(Maker::BuildLogEntry) ? "image" : Maker::FileAttachment.role_for(name)
    end

    # Best-effort; a preview is UX, never part of the write's success (mirrors FilesController).
    def enqueue_preview(node_id:, name:)
      info = FileLayer.current.stat(current_user, node_id:)
      return unless info&.content_token
      ::Maker::Previews::Enqueue.call(user: current_user, node_id:, name:, version_id: info.content_token)
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end

    # The WEB refusal (redirect), not the JSON 501: this is a browser action and the control is only
    # rendered on writable backends. Chunk mode never posts here (it uses the two-phase flow).
    def require_port_writable!
      return if FileLayer.current.capabilities.port_writable?
      redirect_to root_path, alert: "This deployment uploads through the two-phase flow."
    end
  end
end
