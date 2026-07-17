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
  # IT IS ALSO NOT Phase 4's `port_writable`, which asks which upload flow the UI drives. Chunk
  # answers TRUE there (it accepts uploads happily, via Sync::Commit) and FALSE here. Opposite
  # answers for the same backend is the proof they are different questions, not one question
  # wearing two names.
  Capabilities = Data.define(:versioned, :syncable, :presignable, :scannable) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
    def scannable? = scannable
  end
end
