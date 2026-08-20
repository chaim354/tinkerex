module FileLayer
  # What `#begin_upload` hands back: the two-phase presigned flow's phase-1 answer.
  #
  # `node_id` IS ALWAYS PRESENT, WHETHER THE CALLER SUPPLIED ONE OR NOT — `Chunk#begin_upload`
  # mints one when the caller has no reason to choose (a browser upload always creates a new
  # file), and echoes the caller's own choice back when it reused an existing node for a replace
  # (Maker::Addons::LibraryOutput's revision flow). Either way this is the one place to read
  # "which node is this upload becoming" — a caller building a response, or deciding what to do
  # with `missing`, never has to remember which of the two cases it is in.
  #
  # `put_urls` IS A HASH KEYED BY CHUNK HASH, presigned PUT urls for the entries in `missing` —
  # NOT a promise that every entry in `missing` has one. A caller that already holds the bytes
  # (LibraryOutput) writes them directly via Storage::ChunkStore and never reads this field at
  # all; only a browser-side caller (FilesController), which cannot touch the store directly, PUTs
  # to each url and never inspects `missing` itself. The two callers read disjoint halves of this
  # object, which is fine — it is one answer describing one commit, not a contract either caller
  # must fully consume.
  UploadBegun = Data.define(:commit_id, :node_id, :put_urls, :missing)
end
