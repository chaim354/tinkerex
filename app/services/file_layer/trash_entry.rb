module FileLayer
  # One item in this deployment's trash: something the user deleted and CAN GET BACK.
  #
  # NOT a FileInfo, and the difference is the point rather than pedantry. A FileInfo describes a
  # LIVE file and carries a `content_token` you can hand straight to `read` — a trashed file has
  # no such thing on any backend (`read` and `stat` both refuse a tombstone, and the read contract
  # pins that on all three). Reusing FileInfo here would mean a nil content_token: a field whose
  # whole purpose is to be passed back to the port, holding a value the port rejects. And a
  # trashed file has something a live one does not — `deleted_at`, which is the only column the
  # trash view sorts and displays by.
  #
  # `size` is nil for a directory (chunk mode can trash one; share and s3 refuse). That is the
  # honest answer — a directory has no size — and the view renders it as an em-dash, which is the
  # one place in this UI an em-dash is not a lie.
  TrashEntry = Data.define(:node_id, :name, :kind, :size, :deleted_at)
end
