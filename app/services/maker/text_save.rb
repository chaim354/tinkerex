module Maker
  # SAVING TEXT INTO A LIBRARY FILE, ONCE (stage 4, S4-4). Two doors perform this verb —
  # FilesController#update (a file inside a working tree, §14d's git surface) and
  # Projects::ReadmesController#update (the project's README, on any backend, D3's exception) — and
  # a verb more than one controller performs gets a named service rather than being re-inlined
  # (§14d). What must not drift between them is exactly what lives here:
  #
  #   * THE STALE CHECK. The caller edited SOME version; if the port's content token has moved
  #     since, the save would silently discard whatever moved it. 409, never a write.
  #   * `replace: true`, WHICH REUSES THE NODE. A delete-then-create passes any bytes-oriented test
  #     while orphaning every attachment, BOM line and tag on that node — nothing errors and
  #     nothing logs, which is the whole signature (§14a, git-editing.md's opening rule).
  #   * THE PENDING GIT EDIT, gated on `local_worktree?`. On a backend that does not hold the
  #     working tree the bytes still land; there is just no commit box on this box to review them
  #     in.
  #
  # WHAT IS DELIBERATELY NOT HERE: the size cap, the FetchError → 503 mapping, and the preview
  # re-enqueue. The first two are the DOOR's, because each door words them differently and §14a
  # maps FetchError once, at the controller. The third stays with FilesController#update's own
  # `enqueue_preview` (stage 4, S4-3), the helper its two upload actions already share — moving it
  # here would be the third copy of stat-then-Enqueue that helper's comment exists to refuse. This
  # service raises FileLayer errors to its caller unchanged — including the clobber refusal
  # (UnsupportedOperation) a create hits when the name is already taken, which is the honest answer
  # for a file that appeared while the maker was typing.
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
        # would quietly undo whatever removed it. (The opposite race — the door rendered "no file
        # here", a blank token, and one appeared meanwhile — lands in the arm above: the arriving
        # file's token is not blank, so it is STALE, and the port's clobber wording is never the
        # message the maker reads.)
        return refusal(REMOVED)
      end

      node_id = Maker::Addons::LibraryOutput.write_bytes!(
        user, parent_node_id: node ? node.parent_node_id : parent_node_id,
        name: node ? node.name : name, bytes: body.to_s.b, replace: node.present?
      )
      Maker::RepoEdit.record!(user:, repo_root_node_id:, node_id:) if
        repo_root_node_id.present? && FileLayer.current.capabilities.local_worktree?

      Result.new(ok: true, status: :ok, error: nil, node_id:,
                 content_token: FileLayer.current.stat(user, node_id:)&.content_token)
    end

    def self.refusal(message) = Result.new(ok: false, status: :conflict, error: message,
                                           content_token: nil, node_id: nil)
    private_class_method :refusal
  end
end
