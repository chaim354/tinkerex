module FileLayer
  # What this deployment's backend can actually do. The UI reads this to hide
  # Restore/History/Conflicts/Devices rather than offering buttons that fail.
  Capabilities = Data.define(:versioned, :syncable, :presignable) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
  end
end
