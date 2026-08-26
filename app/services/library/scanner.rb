module Library
  # Walks a share-backed library's root and hands what it saw to the Reconciler.
  #
  # This OBSERVES; Library::Reconciler DECIDES. Keeping them apart lets the matching algorithm
  # — the part that makes attachments survive a reorganization — be tested without a filesystem,
  # and lets this half be tested without a database (see #observe).
  #
  # Incremental hashing is the Reconciler's job, not this one's: an Observation carries only
  # what a stat gives (path, size, mtime), so a file whose (path, mtime, size) is unchanged can
  # be skipped without ever being opened. That is what keeps a 2TB archive from being re-read
  # on every pass.
  #
  # The walk is hand-rolled rather than Find/Pathname#find on purpose. `Pathname#find` defaults
  # to `ignore_error: true`, which SILENTLY drops an unreadable directory's entire subtree from
  # the walk — the children simply never appear, and no rescue in the caller's block ever runs.
  # For a scanner whose output feeds a tombstoner, "I couldn't read it" silently rendering as
  # "it isn't there" is the mass-deletion bug itself, wearing the costume of a successful scan.
  # Walking by hand is ~20 lines and makes every error decision explicit and local.
  class Scanner
    # A scan whose input we do not trust enough to act on. Raised from here for a root that is
    # gone, and from the Reconciler for a pass that would tombstone an implausible share of the
    # library — one name, because to an operator they are the same event ("the scan refused") and
    # to a caller they are the same decision (retry later; do not treat this as the truth).
    #
    # It lives on the Scanner rather than the Reconciler because a scan is the operation an
    # operator, ScanJob, and the tests all name. The Reconciler already depends on this class for
    # Observation, so raising Scanner::UnsafeScan adds no coupling that was not already here.
    UnsafeScan = Class.new(StandardError)

    # Never index the trash: doing so re-indexes deleted files as new ones and resurrects them.
    # Root-anchored — we skip the entry and never descend, so no child can be observed either.
    TRASH_PREFIX = ".trash".freeze

    # Never index Share#write's in-flight temp file. It writes bytes to a temp name and renames
    # atomically into place, so a scan landing inside that window would otherwise index the file
    # mid-write and then find it gone. That combination WEDGES THE LIBRARY PERMANENTLY, and it is
    # worth spelling out because neither half is wrong on its own:
    #
    #   1. the scan indexes `.maker-tmp-abc` while its bytes are still torn
    #   2. write renames it to `bracket.stl`, so the temp path vanishes
    #   3. the torn hash can never match the finished file, so the reconciler cannot PAIR them
    #   4. the scan therefore wants to tombstone the ghost — and on a small library that is
    #      100% of one file, over the 20% threshold, so the mass-deletion guard REFUSES the scan
    #   5. the refusal means the ghost is never cleared, so every subsequent scan refuses too
    #
    # Reproduced end-to-end before this constant existed: three consecutive scans all raised
    # `UnsafeScan 1/1 (100.0% > 20%)`. The library never scans again until an operator raises
    # LIBRARY_SCAN_MAX_DELETE_PCT — a permanent wedge from a sub-second race.
    #
    # Matched by PREFIX, not by exact name (the suffix is random), and at every depth rather than
    # root-anchored like the trash: a write into `cad/` puts its temp file in `cad/`, and the temp
    # is ours everywhere it appears. Share#write reads this constant rather than duplicating the
    # string — two copies that must match exactly would resurrect the wedge the moment they drift.
    TEMP_PREFIX = ".maker-tmp-".freeze

    # One filesystem entry as a stat saw it. The definition moved to Library::Observation once a
    # second observer (Phase 3's S3 lister) needed to produce them without being a filesystem
    # walk; this alias is why every call site that names Scanner::Observation still resolves to
    # the one class. `size` is nil for directories, and `content_hash` defaults to nil — see that
    # file for why an observer may supply an identity, and why THIS one never does: a stat cannot
    # know it, and reading the bytes to find out is the exact cost the lazy hash exists to avoid.
    Observation = Library::Observation

    # Returns the scanner, not the reconcile's result, so a caller can ask #unreadable_dirs.
    # ScanJob needs it: "N directories were unreadable" is the operator signal for a half-mounted
    # NAS, and it is needed exactly when the mass-deletion guard does NOT trip — a small
    # unreadable subtree under the threshold otherwise tombstones quietly, with only a per-dir
    # log line to say why. Sync's services return data rather than self; this departs from that
    # because the telemetry is out-of-band from what the reconcile returns.
    def self.call(user, root:, max_delete_pct: nil) = new(user, root:, max_delete_pct:).tap(&:call)

    # `max_delete_pct` overrides the mass-deletion threshold for this scan; nil (all production
    # callers) means the deployment's LIBRARY_SCAN_MAX_DELETE_PCT. It is forwarded rather than
    # left on the Reconciler because the Scanner is the only thing that ever constructs one — a
    # knob the real entry point cannot reach is a knob that only tests can use by mutating ENV.
    def initialize(user, root:, max_delete_pct: nil)
      @user = user
      @root = Pathname.new(root).expand_path
      @max_delete_pct = max_delete_pct
      @unreadable_dirs = []
    end

    # Directories the walk could not list. NOT the same as "empty": their subtrees are absent
    # from the observations through no fault of the filesystem's contents. Anything that
    # tombstones on absence MUST consult this before believing the observations are a complete
    # picture of the tree — #call hands it to the Reconciler, which excludes those subtrees from
    # `vanished_paths` (so nothing under them is tombstoned) and from the mass-deletion guard's
    # denominator (so an unreadable region cannot dilute a real deletion under the threshold).
    attr_reader :unreadable_dirs

    # The root is handed to the Reconciler rather than left for it to look up: it needs to
    # resolve a rel_path back to real bytes to hash it, and reaching for FileLayer.current.root
    # would couple it to the deployment-wide backend — which is Chunk (no root at all) whenever
    # a scan runs outside a share deployment. We already know the root; pass it.
    #
    # The missing-root check is LOAD-BEARING, not belt-and-braces: #each_child rescues ENOENT and
    # returns without recording anything (right for a child vanishing mid-scan), so a root that
    # is gone yields [] observations AND an empty unreadable_dirs — indistinguishable from an
    # empty library by observation alone. It is also the difference between telling an operator
    # "your LIBRARY_PATH does not exist" and handing them a percentage.
    def call
      raise UnsafeScan, "library root #{@root} is missing" unless @root.directory?

      # `observe` must run BEFORE unreadable_dirs is read — it is what fills it. Hence the local
      # rather than inlining the call into the argument list.
      observations = observe
      # unreadable_dirs travels WITH the observations: it is the half of the report that says
      # where we could not look, and the Reconciler must not tombstone on absence there.
      Library::Reconciler.new(@user, observations:, unreadable_dirs:, root: @root,
                                     max_delete_pct: @max_delete_pct).call
    end

    # Walk the tree and return one Observation per entry. Public because it is the whole of this
    # class's own behavior: it is testable with a tmpdir and no database, which is the only
    # coverage this half can have before the Reconciler exists.
    def observe
      @unreadable_dirs = []
      out = []
      # A worklist rather than recursion: the form that makes "descend" an explicit decision
      # made in one place.
      stack = [ [ @root, "" ] ]
      until stack.empty?
        dir, prefix = stack.pop
        each_child(dir, prefix) do |path, rel, stat, name|
          # The dispatch is on an LSTAT, and that is load-bearing for symlink safety rather
          # than incidental: lstat reports a symlink as neither directory? nor file?, so a
          # symlink is never indexed and — crucially — a symlink to a directory is never
          # descended into. Following one would index bytes twice under two paths, and a link
          # pointing OUT of the root would index files the user never put in their library.
          # Switching this to `stat` would silently resolve links and reintroduce both; that is
          # the regression the symlink tests exist to catch.
          if stat.directory?
            out << Observation.new(rel_path: rel, size: nil, mtime: nanos(stat), dir: true)
            # SKIP THE CONTENTS, KEEP THE MARKER — the one skip here that is not a skip of the
            # ENTRY, and the inversion is deliberate. `.trash`, the temp prefix and OsClutter all
            # skip the entry, so no node ever exists; a repo's `.git` dir IS observed and indexed,
            # because that node is the evidence a directory is a working tree and is what
            # Maker::AttachToProject's :in_working_tree asks the database for. Skip it as well and
            # the intake sweep goes back to filing a repo's root files away by category, which git
            # sees as a delete plus an untracked add.
            #
            # It is also not a fifth skip-list wedge, and that is worth stating rather than
            # trusting: the blind spot needs a LIVE NODE at a path no observation can ever pair.
            # Here the marker is observed like any other directory, so it pairs normally, and what
            # we decline is the DESCENT — the one explicit decision this worklist exists to make in
            # one place. The nodes BENEATH it are the ones that must never be minted, which is the
            # write guards' half of the rule. Library::RepoMetadata carries the full argument.
            stack << [ path, rel ] unless Library::RepoMetadata.marker?(name)
          elsif stat.file?
            out << Observation.new(rel_path: rel, size: stat.size, mtime: nanos(stat), dir: false)
          end
          # Anything else — symlink, FIFO, socket, device node — is deliberately not indexed.
          # There are no bytes to serve, and a FIFO would block forever on open (consistent with
          # the special-file EPERM guardrail in the sync path).
        end
      end
      out
    end

    private

    def each_child(dir, prefix)
      names =
        begin
          Dir.children(dir.to_s)
        rescue Errno::ENOENT
          return # vanished mid-scan; the next pass sees the truth
        rescue SystemCallError => e
          # Cannot list this directory: an unmounted NAS, a stale NFS handle, a permissions
          # blip. Record it — its subtree is UNOBSERVED, not gone. Never let this read as
          # absence.
          @unreadable_dirs << (prefix.presence || ".")
          Rails.logger.warn("library scan: cannot list #{display(prefix)}: #{e.class} (#{e.message})")
          return
        end

      names.each do |name|
        # A real NAS holds filenames that are not valid UTF-8: a name written by an old Windows
        # or classic-Mac client arrives from Dir.children as raw bytes tagged with the
        # filesystem encoding. Such a name raises ArgumentError ("invalid byte sequence") the
        # moment anything touches it — Pathname#join, String#count, or an ActiveRecord bind —
        # and ArgumentError is NOT a SystemCallError, so the Reconciler's rescue does not catch
        # it. Because a pass is deliberately un-transactioned, one such file leaves the library
        # half-indexed and kills every subsequent pass at the same entry: the scan never
        # converges, and the error cannot even name the file, since the name is what won't
        # encode.
        #
        # Skip rather than scrub: a scrubbed name no longer resolves back to the real bytes, so
        # we would index a file whose every read 404s. Skipping HERE — in the Scanner — is also
        # what keeps it out of vanished_paths, so an unindexable file can never be tombstoned.
        #
        # No test on macOS can produce this fixture (APFS rejects the name with EILSEQ), and the
        # CI share leg scans an empty tmpdir, so this is pinned at the Reconciler level instead.
        unless name.valid_encoding?
          Rails.logger.warn("library scan: skipping #{name.scrub.inspect} — filename is not " \
                            "valid #{name.encoding}")
          next
        end

        rel = prefix.empty? ? name : "#{prefix}/#{name}"
        next if rel == TRASH_PREFIX
        next if name.start_with?(TEMP_PREFIX) # see TEMP_PREFIX: indexing it wedges the library
        # OS-generated clutter (.DS_Store, ._*, __MACOSX/, macOS volume metadata) — the SAME
        # Library::OsClutter predicate the write guards reject on, so the skip and the refusal
        # cannot drift. Skipping HERE keeps it out of vanished_paths, so an ignored file is never
        # tombstoned. No log line: like the trash skip, this fires on routine noise every scan
        # forever, and logging routine correctness is how a log stops being read.
        next if Library::OsClutter.ignore?(rel)

        path = dir.join(name)
        stat =
          begin
            # lstat, not stat: a symlink must be identified, not resolved (see the dispatch in
            # #observe). One syscall serves the kind test, the size and the mtime — an entry is
            # stat'd exactly once, which matters when the tree is a 2TB archive on a NAS.
            path.lstat
          rescue Errno::ENOENT
            next # vanished mid-scan
          rescue SystemCallError => e
            Rails.logger.warn("library scan: skipping #{display(rel)}: #{e.class} (#{e.message})")
            next
          end

        # `name` travels alongside `rel` so the call site can ask a LEAF question
        # (Library::RepoMetadata.marker?) without rebuilding one. A PREFERENCE, not a necessity:
        # the block also receives `path`, and `path.basename.to_s` is the same string. Passing the
        # name Dir.children already handed us is one derivation fewer to trust, and it leaves the
        # call site reading as the question it asks.
        yield path, rel, stat, name
      end
    end

    def display(rel) = rel.presence&.inspect || "the library root"

    # mtime in unix NANOSECONDS — the sync engine's convention (nodes.mtime is a bigint of
    # nanos; FileInfo's contract says adapters must CONVERT, not pass through). A stat gives
    # seconds plus a nanosecond fraction; feeding st.mtime.to_i straight through is the
    # nanos-as-seconds bug that already shipped for real in the WebDAV and WinFsp adapters.
    # FileLayer::Share#stat passes node.mtime through untouched, so this conversion is the only
    # place the units are established for a share-backed library.
    def nanos(stat) = stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec
  end
end
