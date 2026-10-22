module Files
  # THE WORKBOOK VIEWER'S TWO DOORS (2026-10-21): GET hands the grid its payload, PATCH writes a list
  # of edits back to the SAME library file. JSON both ways, for spreadsheet_controller.js.
  #
  # THE SAVE IS Maker::TextSave, NOT A FOURTH COPY OF IT. Its name says text and its body takes bytes;
  # what must not drift between the doors that rewrite a library file in place is all there — the
  # stale check against the catalog AND the store (`expect_token:`), `replace: true` so the node and
  # everything keyed on it survives, the pending git edit inside a working tree, the preview
  # re-enqueue — and it reaches all three backends through LibraryOutput.write_bytes!: the port's
  # write on share and s3, the two-phase commit on chunk_remote (§14a, git-editing.md's opening
  # rule). This door adds only what is a workbook's: reading the bytes, applying the operations
  # (Maker::Xlsx::Edit), and the bounds.
  #
  # THE TOKEN IS CHECKED HERE BEFORE THE READ, AND AGAIN BY TextSave AT THE WRITE. The operations
  # were made against one version of the file; applied to another they would edit cells the maker
  # never saw. The early check answers the common case — the file changed since the page loaded —
  # before paying for a read and a rebuild; TextSave's two arms close the window between this read
  # and the write. The share caveat git-editing.md records holds here too: on share and s3 the
  # catalog answers from the last scan, and the store arm is what catches a desktop edit made since.
  #
  # BYTES THROUGH RAILS, AS EVERY SERVER-SIDE REWRITE HAS THEM (§15's stated departures): the editor
  # cannot change a zip it has not read, so the read is a port read (a `send_file`-free stream on
  # share, a GET on s3, a chunk download on chunk_remote) bounded by Package::MAX_BYTES on the
  # catalog's own size before any byte moves.
  class SpreadsheetsController < ApplicationController
    # A save is a list of small operations; 5,000 of them at a typical value size is well under a
    # megabyte. The cap stops a body that is something else from being parsed at all.
    MAX_BODY = 8 * 1024 * 1024

    def show
      node = workbook_node or return
      info = FileLayer.current.stat(current_user, node_id: node.node_id)
      return refuse(:unprocessable_entity, too_large) if info.size.to_i > Maker::Xlsx::Package::MAX_BYTES

      bytes = FileLayer.current.read(current_user, node_id: node.node_id)
      workbook = Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(bytes))
      render json: workbook.payload.merge(content_token: info.content_token,
                                          row_cap: Maker::Xlsx::Workbook::ROW_CAP,
                                          col_cap: Maker::Xlsx::Workbook::COL_CAP)
    rescue Maker::Xlsx::Unreadable => e
      refuse(:unprocessable_entity, e.message)
    rescue FileLayer::FetchError => e
      refuse(:service_unavailable, e.message)
    rescue FileLayer::NotFound
      refuse(:not_found, Maker::TextSave::REMOVED)
    end

    def update
      node = workbook_node or return
      if request.content_length.to_i > MAX_BODY
        return refuse(:payload_too_large, "Too many changes to save at once. Save more often.")
      end

      base_token = params[:base_token].to_s
      info = FileLayer.current.stat(current_user, node_id: node.node_id)
      return refuse(:conflict, Maker::TextSave::STALE) if info.content_token.to_s != base_token
      return refuse(:unprocessable_entity, too_large) if info.size.to_i > Maker::Xlsx::Package::MAX_BYTES

      bytes = Maker::Xlsx::Edit.apply(FileLayer.current.read(current_user, node_id: node.node_id), params[:ops])
      root = Library::WorkingTree.new(current_user).root_for(node)
      result = Maker::TextSave.call(user: current_user, node:, parent_node_id: node.parent_node_id,
                                    name: node.name, body: bytes, base_token:, repo_root_node_id: root&.node_id)
      return refuse(result.status, result.error) unless result.ok

      render json: { ok: true, content_token: result.content_token }
    rescue Maker::Xlsx::Refused, Maker::Xlsx::Unreadable => e
      refuse(:unprocessable_entity, e.message)
    rescue FileLayer::FetchError => e
      refuse(:service_unavailable, e.message)
    rescue FileLayer::NotFound
      refuse(:conflict, Maker::TextSave::REMOVED)
    end

    private

    # The maker's own live file, and a workbook by name — the same vocabulary the file page asked
    # (FilePreview::SPREADSHEET_EXTS), so the two cannot disagree about which files have this door.
    def workbook_node
      node = current_user.nodes.present.find_by(node_id: params[:file_id], kind: "file")
      return node if node && FilePreview::SPREADSHEET_EXTS.include?(File.extname(node.name).downcase.delete("."))

      refuse(:not_found, "That workbook is not in your library.")
      nil
    end

    def too_large = "This workbook is too large to open here. Download it to open it in Excel or LibreOffice."

    def refuse(status, message) = render(json: { ok: false, error: message }, status:)
  end
end
