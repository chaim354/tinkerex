module Maker
  # SAVING TEXT INTO A LIBRARY FILE, ONCE (stage 4, S4-4). Two doors perform this verb —
  # FilesController#update (a file inside a working tree, §14d's git surface) and
  # Projects::ReadmesController#update (the project's README, on any backend, D3's exception) — and
  # a verb more than one controller performs gets a named service rather than being re-inlined
  # (§14d). What must not drift between them is exactly what lives here:
  #
  #   * THE STALE CHECK. The caller edited SOME version; if the port's content token has moved
  #     since, the save would silently discard whatever moved it. 409, never a write. IT SEES THE
  #     CATALOG'S TOKEN, NOT THE DISK'S: on share and s3 `stat` answers from the row, so a desktop
  #     edit or deletion the scan has not observed yet is invisible here until it is (§14b's
  #     bounded staleness — measured in S4-4's review, a Finder edit made between render and Save
  #     with no scan in between was overwritten). The no-history note on the editor is what tells
  #     the maker that; closing the gap is a port question, not a door's.
  #   * `replace: true`, WHICH REUSES THE NODE. A delete-then-create passes any bytes-oriented test
  #     while orphaning every attachment, BOM line and tag on that node — nothing errors and
  #     nothing logs, which is the whole signature (§14a, git-editing.md's opening rule).
  #   * THE PENDING GIT EDIT, recorded only when the caller NAMED a repo root AND the backend
  #     holds the working tree (`local_worktree?`). On one that does not, the bytes still land;
  #     there is just no commit box on this box to review them in.
  #
  #   * THE PREVIEW RE-ENQUEUE. A save invalidates the picture of the file (stage 4, S4-3), and
  #     every text extension has a renderer (Registry derives TextThumb), so a saved file kept
  #     serving a thumbnail of bytes it no longer had until the next scan noticed. S4-3 said so in
  #     FilesController#update through its private `enqueue_preview`; a README saved from the
  #     project page would have left the same stale picture on the Files page, and a second door
  #     calling a helper private to the first is not a shape that lasts. `LibraryOutput
  #     .enqueue_preview` is the ONE stat-then-enqueue for bytes written server-side, and it hands
  #     back the token it keyed the thumbnail on — so the token `replace: true` just minted reaches
  #     the Result from the same stat, one stat, two consumers, no fourth copy. BEST-EFFORT: a
  #     vanished or unmounted library (NotFound, FetchError) leaves `content_token` nil rather than
  #     turning a save that reached the store into an error.
  #
  # WHAT IS DELIBERATELY NOT HERE: the size cap and the FetchError → 503 mapping. Both are the
  # DOOR's, because each door words them differently and §14a maps FetchError once, at the
  # controller. This service raises FileLayer errors to its caller unchanged — including the clobber
  # refusal (UnsupportedOperation) a create hits when the name is already taken. THAT REFUSAL AND
  # THE STALE ARM ARE TWO HALVES OF ONE RACE, "a file appeared while the maker was typing": once
  # the catalog has seen the arrival the door resolves it and the save lands in STALE; before it has
  # (share until the next scan, chunk_remote's mirror lag) the door resolves nothing, the create
  # reaches the port, and the port refuses the clobber. Both refuse; neither writes.
  class TextSave
    Result = Data.define(:ok, :status, :error, :content_token, :node_id)

    STALE = "This file changed since you opened it. Reload to see the current version.".freeze
    REMOVED = "This file was removed since you opened it. Reload to see the current state.".freeze

    # node: the live Node being rewritten, or nil to CREATE `name` under `parent_node_id`.
    def self.call(user:, node:, parent_node_id:, name:, body:, base_token:, repo_root_node_id: nil)
      if node
        info = FileLayer.current.stat(user, node_id: node.node_id)
        return refusal(STALE) if info&.content_token.to_s != base_token.to_s
      elsif base_token.present?
        # A CREATE THAT CARRIES A TOKEN IS A SAVE AGAINST A FILE THAT HAS SINCE GONE: the token is
        # the door's own render of a file that existed then, and the door resolves no file now.
        # Refused rather than recreated — the maker has not seen that it went, and a create here
        # would quietly undo whatever removed it, once the catalog has noticed the removal (before
        # that the row is still live, the arm above answers, and the write recreates the file — the
        # same catalog-bounded window the header names). The opposite race — "no file here" was
        # rendered, a blank token, and one appeared — is the two-halves race in the header.
        return refusal(REMOVED)
      end

      node_id = Maker::Addons::LibraryOutput.write_bytes!(
        user, parent_node_id: node ? node.parent_node_id : parent_node_id,
        name: node ? node.name : name, bytes: body.to_s.b, replace: node.present?
      )
      Maker::RepoEdit.record!(user:, repo_root_node_id:, node_id:) if
        repo_root_node_id.present? && FileLayer.current.capabilities.local_worktree?

      # The token the write just minted, with the thumbnail re-enqueued against it — nil, and
      # nothing enqueued, when the library can no longer answer for the node (see the header).
      token = Maker::Addons::LibraryOutput.enqueue_preview(user, node_id, node ? node.name : name)
      Result.new(ok: true, status: :ok, error: nil, node_id:, content_token: token)
    end

    def self.refusal(message) = Result.new(ok: false, status: :conflict, error: message,
                                           content_token: nil, node_id: nil)
    private_class_method :refusal
  end
end
