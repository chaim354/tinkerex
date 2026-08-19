module Projects
  # Inline "upload a new file and attach it", for the WRITABLE backends (share/s3): the bytes come
  # up in ONE multipart POST and go straight to the port — the same single FileLayer.current.write
  # FilesController#create makes, plus an attach. No chunk path here: chunk mode's inline upload is
  # the browser two-phase flow (uploader_controller.js) which lands the node via /files/{begin,
  # finalize}_upload, then POSTs the node_id to the attach endpoint. So this never reaches into the
  # sync engine (spec §10) — it is the SAME write door FilesController already uses on these
  # backends. One controller serves both a project target and a build-log-entry target.
  class UploadsController < ApplicationController
    before_action :require_port_writable!

    # The eager nudge (Task 11) — #intake_project_folder, called from #create below. Shared with
    # FilesController, the other two upload doors; see the concern's header for why a shared module
    # rather than a second copy.
    include ProjectFolderIntake

    # The port's write can refuse (UnsupportedOperation — e.g. a name already at the library root,
    # a current-state-only clobber) or be temporarily unreachable (FetchError — unmounted NAS,
    # bucket blip). FilesController maps these on its write path; this parallel path must too, or an
    # ordinary duplicate-name upload 500s instead of showing a flash. Browser action -> redirect
    # back to where the upload button was (the project page), with an alert.
    rescue_from FileLayer::UnsupportedOperation do
      redirect_back_or_to projects_path,
                          alert: "Couldn't upload that file — a file with the same name may already exist."
    end
    rescue_from FileLayer::FetchError do
      redirect_back_or_to projects_path, alert: "Couldn't reach your library. Try again."
    end

    def create
      file = params.require(:file)
      target = attach_target
      info = FileLayer.current.write(current_user, parent_node_id: upload_parent(target),
                                     name: file.original_filename, io: file)
      enqueue_preview(node_id: info.node_id, name: file.original_filename)
      target.file_attachments.create!(user: current_user, node_id: info.node_id,
                                      role: role_for(file.original_filename, target))
      # AFTER the create! above, NOT BEFORE — the order is load-bearing, and backwards it 500s.
      # For a PROJECT target this file just landed at that SAME project's folder root, so
      # Maker::ProjectIntake.for_node resolves the SAME project and its own #attach step would try
      # to insert the IDENTICAL (user, "Maker::Project", project.id, node_id) tuple the line above
      # just inserted. insert_all's unique_by: makes THAT collision a silent skip -- but only
      # because it runs SECOND and finds the row already there. Reversed, the bare `create!` above
      # would be the one landing second, hit index_maker_file_attachments_uniqueness the ORDINARY way (a
      # bang method on a real duplicate), and raise ActiveRecord::RecordNotUnique, uncaught, on
      # every single project upload through this door. A build-log-entry TARGET never collides
      # either way -- #upload_parent sends it to the library root, not a project folder, so
      # for_node's owning_project resolves nil and #attach never runs for it -- but the ordering
      # requirement is about the PROJECT case, so it is written as an invariant, not "usually fine".
      #
      # THE RETURN VALUE IS NOW READ, NOT DISCARDED (see ProjectFolderIntake's header) -- so a
      # same-named upload whose eager nudge lost a collision at its destination folder says so in
      # the flash below (#project_intake_notice), instead of a bare "Uploaded" that hid it.
      intake_result = intake_project_folder(info.node_id)
      redirect_to after_upload_url(target), notice: project_intake_notice(intake_result, file.original_filename)
    end

    private

    # WHERE THE BROWSER LANDS AFTER THE UPLOAD. The default is the project page, so every caller
    # that omits `redirect_url` — the project page's own uploader, a build-log entry — is unchanged.
    # The Files-page current-project uploader passes `redirect_url: files_path(...)` so the user
    # stays in Files instead of being bounced to the project (parity with the chunk branch, which
    # already honors it via uploader_controller.js).
    #
    # `url_from` is Rails' own open-redirect guard (its docs show exactly `url_from(params[...])`):
    # it returns the location ONLY for a same-host or leading-single-slash RELATIVE path, and nil
    # for a foreign host, a scheme, or a protocol-relative `//` — so a tampered field can never send
    # the user off this app; it just falls back to the project page. Without it a bad value would
    # raise OpenRedirectError (a 500), not merely leak a redirect.
    def after_upload_url(target)
      url_from(params[:redirect_url]) || project_path(project_of(target))
    end

    # Exactly one of the two nested routes supplies the target.
    def attach_target
      if params[:build_log_entry_id].present?
        current_user.maker_build_log_entries.find(params[:build_log_entry_id])
      else
        current_user.maker_projects.find_by!(slug: params[:project_id])
      end
    end

    def project_of(target) = target.is_a?(Maker::BuildLogEntry) ? target.project : target

    # Project uploads go into the project's Projects/<slug> folder; build-log entry-photo uploads
    # stay at the library root (v1 scope — spec Out of scope).
    def upload_parent(target)
      return nil if target.is_a?(Maker::BuildLogEntry)
      project_of(target).ensure_library_folder!(current_user).node_id
    end

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
