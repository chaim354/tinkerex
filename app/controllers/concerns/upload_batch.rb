# WRITING SEVERAL FILES THROUGH THE PORT IN ONE REQUEST (slice 0, 2026-09-10).
#
# Both upload doors took exactly one file — `projects/_upload_control` and `files/index` rendered a
# file field with no `multiple`, so a maker with a dozen project files opened the picker a dozen
# times. (The Files page's field has been the top bar's since redesign slice 4,
# layouts/_topbar_upload.html.erb; it posts to the same door.) The model importer next door has always accepted a batch, so the app already knew how; the
# two doors a maker actually lives in did not.
#
# ONE FILE'S FAILURE MUST NOT LOSE THE OTHERS, which is the whole reason this is a shared loop
# rather than `uploads.each` at each call site. Both controllers previously let
# FileLayer::UnsupportedOperation and FetchError reach a `rescue_from` that redirects — correct for
# one file, and for a batch it would abandon files 4 and 5 because file 3 hit a name that was
# already taken. So each write is isolated here and the refusal is REPORTED
# (ProjectFolderIntake#refused_sentence) instead of thrown away: a batch that silently drops a file
# is worse than one that refuses loudly.
#
# ORDER IS PRESERVED and writes are sequential, deliberately. The port's clobber check is a
# head-then-put CHECK, NOT A LOCK on S3 (§14a), and two files of the same name arriving in one
# selection would race a parallel implementation into a silent overwrite; sequential writes make
# the second one lose the ordinary way, with a message.
module UploadBatch
  extend ActiveSupport::Concern

  # Returns [written, refused, errors]:
  #   written — the FileLayer::FileInfo of every file that landed, in selection order
  #   refused — { filename => reason }, in selection order, for anything the port turned away
  #   errors  — the exceptions themselves, so a SINGLE-file caller can re-raise and let the
  #             controller's existing `rescue_from` answer exactly as it did before this concern
  #             existed. That is not tidiness: swallowing the exception here broke the JSON door.
  #             `measure_controller.js` saves through `uploadPortFile`, which reads `data.error`
  #             off a 422 to show "… already exists" IN WORDS; with the raise absorbed, the empty
  #             batch redirected instead, fetch followed it to an HTML page, and the user saw
  #             "upload failed (406)". Caught by the system leg, which is the only one that drives
  #             that door.
  #
  # Yields each FileInfo (with its upload) so a caller that must do more per file — attaching to a
  # project, say — can, without this concern learning what an attachment is.
  def write_batch(uploads, parent_node_id:)
    written = []
    refused = {}
    errors  = []

    # ANYTHING THAT IS NOT AN UPLOADED FILE IS DROPPED, not trusted to answer #original_filename.
    # `include_hidden: false` on both forms stops the empty marker at source, but this param is
    # user-controlled and a hand-made POST can carry a String, a Hash or nothing at all; a 500 is
    # the wrong answer to a malformed upload.
    uploads.select { |u| u.respond_to?(:original_filename) }.each do |upload|
      name = upload.original_filename
      begin
        info = FileLayer.current.write(current_user, parent_node_id:, name:, io: upload)
        enqueue_preview(node_id: info.node_id, name:)
        yield(info, upload) if block_given?
        written << info
      rescue FileLayer::UnsupportedOperation => e
        # "already exists" IS THE ESTABLISHED WORDING AND IS PINNED, on both writable backends
        # (share_delivery_test, s3_write_test). §14a records why: a clobber used to raise NotFound,
        # so the app told a maker the file was "not found" while they could see it in the list
        # behind the alert. Any rewording here has to keep saying the name is taken.
        refused[name] = "a file of that name already exists"
        errors << e
      rescue FileLayer::FetchError => e
        refused[name] = "the library could not be reached"
        errors << e
      end
    end

    [ written, refused, errors ]
  end
end
