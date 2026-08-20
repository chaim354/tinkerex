module FileLayer
  # What `#finalize_upload` hands back: the two-phase presigned flow's phase-2 answer.
  #
  # `version_id`/`seq` ARE ALWAYS PRESENT — the commit either finalized (in which case both are
  # real) or `#finalize_upload` raised (ChunksMissing) and there is no UploadFinalized at all. They
  # sit OUTSIDE `info` rather than inside it because FilesController's JSON response reads
  # `version_id` unconditionally, even along the (belt-and-braces, see `info` below) branch where
  # `info` is nil — collapsing them into `info` would lose version_id exactly where a caller still
  # needs it.
  #
  # `info` CAN BE NIL, EVEN THOUGH A SUCCESSFUL FINALIZE JUST WROTE THE NODE IN THE SAME
  # TRANSACTION `Sync::Commit.finalize` ran. It should be un-reachable in practice — by the time
  # `finalize` returns, its transaction has committed, so the very next read on the same connection
  # must see the row — but `Chunk#finalize_upload` preserves the nil case anyway because it is
  # exactly what both of `Sync::Commit.finalize`'s EXISTING callers already guarded against
  # (`V1::CommitsController#finalize` and, before this task, FilesController#finalize_upload
  # itself), each with its own `if node` before running the post-finalize side effects. This port
  # method keeps that shape rather than asserting a guarantee neither caller was written to trust.
  #
  # `info` DOES NOT NECESSARILY DESCRIBE WHAT THIS CALL JUST WROTE, AND THAT IS ITS `FileInfo`
  # CONTRACT, NOT A BUG — it is built the same way `#stat` builds one, from the node's CURRENT
  # state, which is what every other `FileInfo`-returning port verb promises. On the ordinary
  # fast-forward path that is exactly the content this call committed. Under a conflict
  # (Sync::Commit.finalize's own is_conflict branch — this commit's base was no longer current), the
  # node's live content_token still points at whatever was already current, not at the version this
  # call just created; describing "the node's current state" honestly is preferable to a second,
  # `#stat`-inconsistent meaning of FileInfo that exists only here.
  UploadFinalized = Data.define(:version_id, :seq, :info)
end
