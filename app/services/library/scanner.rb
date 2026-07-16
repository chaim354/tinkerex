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

    # One filesystem entry as a stat saw it. `size` is nil for directories (a directory's
    # st_size is an allocation detail — 96, 4096 — and storing it in nodes.size would be
    # meaningless bytes in a column that means "how big is this file").
    Observation = Data.define(:rel_path, :size, :mtime, :dir)

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
        each_child(dir, prefix) do |path, rel, stat|
          # The dispatch is on an LSTAT, and that is load-bearing for symlink safety rather
          # than incidental: lstat reports a symlink as neither directory? nor file?, so a
          # symlink is never indexed and — crucially — a symlink to a directory is never
          # descended into. Following one would index bytes twice under two paths, and a link
          # pointing OUT of the root would index files the user never put in their library.
          # Switching this to `stat` would silently resolve links and reintroduce both; that is
          # the regression the symlink tests exist to catch.
          if stat.directory?
            out << Observation.new(rel_path: rel, size: nil, mtime: nanos(stat), dir: true)
            stack << [ path, rel ]
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
        rel = prefix.empty? ? name : "#{prefix}/#{name}"
        next if rel == TRASH_PREFIX

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

        yield path, rel, stat
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
