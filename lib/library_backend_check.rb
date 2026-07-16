# Refuse to boot a share-backed deployment whose library root is unusable, rather than surfacing
# it as a 500 on the first request. Mirrors lib/postgres_pooler_check.rb, which exists for the
# same reason: a misconfiguration that only shows up later is worse than one that stops the boot.
#
# WHAT THIS DOES *NOT* CATCH: an unmounted share. An unmounted mount point is a real, readable,
# EMPTY directory — File.exist? and File.directory? both return true for it — so no check here can
# distinguish "mounted" from "unmounted" (FileLayer::Share#library_present? uses emptiness as the
# signal at read time, where it belongs; an empty root is legitimate at boot, e.g. a brand-new
# library, so it must not stop the boot). This guard catches the configuration errors it actually
# can: a LIBRARY_PATH that is unset, typo'd, pointing at a file, or unreadable.
#
# Read-only for now (phase 2a indexes an existing library); phase 2b adds the write path and
# should extend this to require writability.
module LibraryBackendCheck
  Error = Class.new(StandardError)

  # Reads the same ENV vars, with the same default, as FileLayer.build — the factory calls this
  # too, so a bad LIBRARY_PATH gets this explanation even when the boot guard did not run (the
  # test env) or when ENV changed after boot.
  def self.check!(backend: ENV.fetch("LIBRARY_BACKEND", "chunk"), path: ENV["LIBRARY_PATH"])
    return unless backend == "share"

    raise Error, "LIBRARY_BACKEND=share requires LIBRARY_PATH (the mounted directory to index)" if path.blank?
    unless File.exist?(path)
      raise Error, "LIBRARY_PATH #{path.inspect} does not exist — check the path is spelled " \
                   "correctly and that the mount point has been created"
    end
    raise Error, "LIBRARY_PATH #{path.inspect} is not a directory" unless File.directory?(path)
    raise Error, "LIBRARY_PATH #{path.inspect} is not readable" unless File.readable?(path)
  end
end
