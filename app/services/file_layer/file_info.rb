module FileLayer
  # What the port knows about one file, independent of backend.
  #
  # `content_token` identifies the file's CURRENT CONTENT STATE. In chunk mode it is the
  # immutable version UUID (bytes are restorable); in share/S3 mode it will be the content
  # hash (identifies the bytes, does NOT imply they are recoverable). It is the value stored
  # in the `version_id` column on maker_previews / maker_file_attachments — same value,
  # backend-neutral name.
  #
  # `mtime` is **unix nanoseconds** — the sync engine's end-to-end convention (the `nodes.mtime`
  # column is a bigint of nanos; see CLAUDE.md §7). Adapters must CONVERT, not pass through: a
  # filesystem stat yields a Time/seconds, and feeding that in directly is the nanos-overflow bug
  # already shipped once in the WebDAV and WinFsp adapters, which read the value as seconds.
  FileInfo = Data.define(:node_id, :name, :kind, :size, :mtime, :content_token)
end
