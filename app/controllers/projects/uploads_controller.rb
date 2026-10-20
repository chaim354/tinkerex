module Projects
  # A build-log entry's inline photo upload, for the WRITABLE backends (share/s3). The bytes come up
  # in ONE multipart POST and go straight to the port, through the same FileLayer.current.write that
  # FilesController#create makes, and each file that lands is attached to the entry as an image. No
  # chunk path here: chunk mode's inline upload is the browser two-phase flow
  # (uploader_controller.js), which lands the node via /files/{begin,finalize}_upload and then POSTs
  # the node_id to entry_photos_path. So this never reaches into the sync engine (spec §10).
  #
  # ONE TARGET SINCE F-S21-1 (2026-10-19). This controller also served a project-level route,
  # POST /projects/:slug/uploads, the project page's own uploader until redesign slice 4 moved the
  # hub's Upload into the top bar. The top bar posts to FilesController with the project's folder as
  # the parent, and the intake sweep attaches. The old route kept no caller in the app, and it gave
  # "upload into this project" a second answer that disagreed with the first: a different folder
  # lookup, an attach ahead of the sweep, a different landing page and different wording. It is
  # gone, and so are the second target type and the attach-before-intake ordering rule it alone
  # needed.
  class UploadsController < ApplicationController
    before_action :require_port_writable!
    # THE SHARED DEMO'S PER-FILE CAP ON THE THIRD UPLOAD DOOR (Tinkerex::Demo) -- FilesController caps
    # its two; this door is the project page's build-log uploader, live on s3, which is what the
    # public box runs. The whole selection is refused if one file is over, so nothing is written (the
    # same rule as FilesController#refuse_oversized_demo_upload!, whose comment has the argument).
    before_action :refuse_oversized_demo_upload!, only: :create

    # #batch_upload_notice and #refused_sentence, the sentences both upload doors answer a batch
    # with. NOT the eager nudge (#intake_project_folder): this door writes at the library root, which
    # no project owns, so the nudge would answer nil for every file it could be handed.
    include ProjectFolderIntake
    include UploadBatch

    # THE PORT'S THREE PER-FILE ANSWERS, for a SINGLE file (UploadBatch reports them for a batch and
    # re-raises only when one file was sent). Browser action -> redirect back to where the upload
    # button was (the project page, whose build-log entries carry it), with an alert.
    #
    # UnsupportedOperation = the name is taken at the library root (a current-state-only clobber).
    rescue_from FileLayer::UnsupportedOperation do
      redirect_back_or_to projects_path,
                          alert: "Couldn't upload that file — a file with the same name may already exist."
    end
    # FetchError = the library is unreachable right now (unmounted NAS, bucket blip). Retryable.
    rescue_from FileLayer::FetchError do
      redirect_back_or_to projects_path, alert: "Couldn't reach your library. Try again."
    end
    # NotFound = the port will not store THIS file: a name the library reserves (`._x`, `.DS_Store`,
    # `.git`), a name that is not a leaf, or more than FileLayer::MAX_BYTES (a long phone video). It
    # is not "not found" here; it is the class both writable adapters raise for those conditions
    # (FileLayer::Share#write). With no arm, this door answered all of them with a 500 (F-S21-2).
    # Name or size is the whole list at this door, because its destination is the library root and a
    # vanished parent cannot happen.
    rescue_from FileLayer::NotFound do
      redirect_back_or_to projects_path,
                          alert: "Couldn't upload that file — the library cannot store a file " \
                                 "with that name or size."
    end

    def refuse_oversized_demo_upload!
      return unless Tinkerex::Demo.demo?(current_user)

      refusal = Array(params[:file]).select { |u| u.respond_to?(:original_filename) }.lazy.filter_map { |u|
        Tinkerex::Demo.upload_refusal(current_user, name: u.original_filename, size: u.size)
      }.first
      redirect_back_or_to(projects_path, alert: refusal) if refusal
    end

    # Photos go to the library ROOT (v1 scope — spec Out of scope). The attach runs inside the
    # per-file block, so each photo that lands is attached and a refused one attaches nothing.
    def create
      entry = current_user.maker_build_log_entries.find(params[:build_log_entry_id])
      files = Array(params.require(:file))

      written, refused, errors = write_batch(files, parent_node_id: nil) do |info|
        entry.file_attachments.create!(user: current_user, node_id: info.node_id, role: "image")
      end

      if written.empty?
        # One file refused is the pre-batch condition; re-raise so this controller's own
        # `rescue_from` answers it with the wording it has always used.
        raise errors.first if files.size == 1 && errors.any?

        return redirect_to(after_upload_url(entry), alert: refused_sentence(refused))
      end

      redirect_to after_upload_url(entry), notice: batch_upload_notice(written.map(&:name), nil, refused:)
    end

    private

    # WHERE THE BROWSER LANDS AFTER THE UPLOAD. The default is the entry's project page; a caller may
    # pass `redirect_url` to land somewhere else (parity with the chunk branch, which honors it via
    # uploader_controller.js). Its one caller in the app is a build-log entry's inline upload
    # (projects/_log_entry.html.erb), which names the project page.
    #
    # `url_from` is Rails' own open-redirect guard (its docs show exactly `url_from(params[...])`):
    # it returns the location ONLY for a same-host or leading-single-slash RELATIVE path, and nil
    # for a foreign host, a scheme, or a protocol-relative `//` — so a tampered field can never send
    # the user off this app; it just falls back to the project page. Without it a bad value would
    # raise OpenRedirectError (a 500), not merely leak a redirect.
    def after_upload_url(entry)
      url_from(params[:redirect_url]) || project_path(entry.project)
    end

    # The WEB refusal (redirect), not the JSON 501: this is a browser action and the control is only
    # rendered on writable backends. Chunk mode never posts here (it uses the two-phase flow).
    def require_port_writable!
      return if FileLayer.current.capabilities.port_writable?
      redirect_to root_path, alert: "This deployment uploads through the two-phase flow."
    end
  end
end
