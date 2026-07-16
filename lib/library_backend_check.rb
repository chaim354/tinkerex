# Refuse to boot a share-backed deployment whose library root is unusable, rather than surfacing
# it as a 500 on the first request. Mirrors lib/postgres_pooler_check.rb, which exists for the
# same reason: a misconfiguration that only shows up later is worse than one that stops the boot.
#
# WHAT THIS DOES *NOT* CATCH: an unmounted share. An unmounted mount point is a real, readable,
# writable, EMPTY directory — File.exist? and File.directory? both return true for it, and the
# write probe below SUCCEEDS on it (onto the underlying disk) — so no check here can distinguish
# "mounted" from "unmounted" (FileLayer::Share#library_present? uses emptiness as the signal at
# read time, where it belongs; an empty root is legitimate at boot, e.g. a brand-new library, so
# it must not stop the boot). This guard catches the configuration errors it actually can: a
# LIBRARY_PATH that is unset, typo'd, pointing at a file, unreadable, or not writable.
#
# ALSO NOT CAUGHT — a leaked probe, which is this guard's own contribution to the list above. The
# probe writes a file and unlinks it in an `ensure`, so every ordinary failure cleans up; a
# SIGKILL between the two does not, and the leaked dotfile then makes Share#library_present? read
# an unmounted share as mounted (emptiness is its signal), turning every retryable FetchError into
# a terminal NotFound until someone removes the file. That is the SAME known hole its header
# already names for a stale .DS_Store, not a new class, and it is a deliberate trade: probing
# nothing would swap a rare, self-inflicted false-mounted for a routine, silent read-only library
# that fails on the first upload instead of at boot. The probe is named with the Scanner's
# TEMP_PREFIX so a leak is at least never INDEXED (see #writable!).
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
    # LAST, and the order is the operator's error message: a missing root must say "does not
    # exist", not "is not writable". Every check above answers a question this one cannot even
    # ask — you cannot meaningfully probe a path that is a file, or one that isn't there.
    writable!(path)
  end

  # A REAL write, not File.writable?. File.writable? tests POSIX mode bits against the process
  # uid/gid — it does not consult NFSv4/SMB ACLs, an SMB share's read-only export flag, or a
  # remount-ro, and every one of those is a live possibility for the mounted directory this
  # backend exists to serve. On those it cheerfully answers true for a root we cannot write, and
  # the operator learns the truth from a failed upload instead of a refused boot. The only honest
  # question is "can we create a file here?", so ask it.
  #
  # NOTE for whoever revisits this: no unit test can tell the two implementations apart, because
  # only an ACL-bearing filesystem can — substituting `File.writable?` here keeps the whole suite
  # green. The touch-probe is justified by the DEPLOYMENT TARGET, not by a red test. Do not
  # "simplify" it back on the evidence of the tests.
  #
  # Named with the Scanner's TEMP_PREFIX (which it skips at every depth) rather than a prefix of
  # this file's own invention, and the reason is a wedge rather than tidiness: the Scanner walks
  # this root every 15 minutes, a boot can land inside a scan, and a probe it INDEXED would vanish
  # on unlink — an observation that can never pair, whose tombstone trips the mass-deletion guard
  # and refuses that scan and every scan after it. Share#write reuses the same constant for the
  # same reason; see Library::Scanner::TEMP_PREFIX, which documents the reproduction. The random
  # suffix means two boots (or a boot racing a purge) cannot collide on the name.
  #
  # That reference has a REAL COST, and it is paid at the call site: this is lib/ reaching into
  # app/, and app/ constants are not autoloadable while initializers run — calling this from an
  # initializer's top level raises `uninitialized constant Library` and takes the boot down for
  # the wrong reason (observed, not theorized). config/initializers/library_backend_check.rb
  # therefore calls check! from after_initialize. Any NEW caller earlier than that must either do
  # the same or not call this method.
  def self.writable!(path)
    probe = File.join(path, "#{Library::Scanner::TEMP_PREFIX}probe-#{Process.pid}-#{SecureRandom.hex(4)}")
    begin
      File.binwrite(probe, "")
    rescue SystemCallError => e
      raise Error, "LIBRARY_PATH #{path.inspect} is not writable (#{e.class}: #{e.message}) — " \
                   "phase 2b writes uploads and moves deletes into .trash/, so a read-only " \
                   "share cannot back a library. Check the mount options and the export's " \
                   "permissions for the user this process runs as."
    ensure
      # MUST NOT leak — see the header. Share#library_present? reads "the root is empty" as
      # "unmounted", so a stale probe would make an unmounted share look mounted and flip every
      # transient ENOENT to a terminal NotFound.
      begin
        File.unlink(probe)
      rescue SystemCallError
        nil
      end
    end
  end
end
