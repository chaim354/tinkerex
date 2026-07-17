module FileLayer
  # What this deployment's backend can actually do. The UI reads this to hide
  # Restore/History/Conflicts/Devices rather than offering buttons that fail.
  #
  # SCANNABLE is the odd one out and is worth naming carefully, because it was added (Phase 3) to
  # fix a bug the other three could not express. It asks ONE question:
  #
  #     does this backend's catalog come from POLLING the store?
  #
  # Chunk: no. Its tree arrives through the sync engine's changelog — devices push, the server
  # appends, `nodes` is authoritative by construction. There is nothing to scan and nothing that
  # could change behind our back. Share and S3: yes. The bytes live in storage the USER also
  # writes to (Finder, rclone, the S3 console), so the only way to learn the truth is to go and
  # look — periodically, forever (spec decision 5).
  #
  # IT IS NOT `!syncable?`, and the fact that it currently equals it is a coincidence of having
  # exactly three backends. `syncable` asks whether devices maintain this tree via the changelog;
  # `scannable` asks whether the server learns the store's truth by polling. A backend that gets
  # push notifications instead (S3 event notifications, a webhook, a NAS that actually emits usable
  # change events) would answer false to BOTH — and deriving one from the other would schedule a
  # 15-minute poll against it forever. Two questions that happen to share an answer today are still
  # two questions; the whole reason this capability exists is that a coincidence was encoded once
  # already (`is_a?(Share)`) and silently became wrong when the second backend arrived.
  #
  # PORT_WRITABLE answers ONE question, for ONE caller — the upload form:
  #
  #     which upload flow does the UI drive?
  #
  # true -> POST the bytes to the port (FileLayer#write). Share, S3.
  # false -> drive Sync::Commit's two-phase presigned flow. Chunk.
  #
  # IT IS NOT "can this deployment accept uploads". Chunk mode accepts uploads all day — that is
  # what Sync::Commit is — and reading the name that way hides the upload button in the product's
  # MAIN deployment. The name is about the PORT's write path, not the deployment's.
  #
  # It is NOT derived from `!syncable?` either, though the two agree on all three backends today
  # and the correlation is even causal (the two-phase flow exists BECAUSE of sync). Deriving it
  # spells the answer as an inference chain — syncable -> the sync engine owns writes -> the port
  # refuses — and an inference chain breaks silently. One stated answer beats a correct guess.
  #
  # AND IT IS NOT `scannable`. They agree on every backend we have (chunk false/false, share and
  # s3 true/true), so the distinction has to be argued rather than observed: `scannable` asks
  # where the CATALOG comes from, `port_writable` asks which door BYTES go in. The same
  # notification-driven backend that splits `scannable` from `!syncable?` above splits this too —
  # push-notified, so scannable false, while its uploads still go through the port. Agreement
  # across three samples is not identity; it is three samples.
  #
  # (An earlier version of this comment claimed chunk answers TRUE to port_writable, on the
  # rejected "accepts uploads" reading, and used that to argue port_writable and scannable are
  # opposites. Both halves were wrong: chunk answers false, and the two capabilities agree
  # everywhere. The argument above is the one that survives contact with the real values.)
  Capabilities = Data.define(:versioned, :syncable, :presignable, :scannable, :port_writable) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
    def scannable? = scannable
    def port_writable? = port_writable
  end
end
