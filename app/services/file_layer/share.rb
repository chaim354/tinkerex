module FileLayer
  # A plain mounted directory (SMB/NFS) the user owns and manages. There are no chunks and no
  # versions: the file on disk IS the truth, so `content_token` is its content hash — it
  # identifies the bytes but does NOT imply they are recoverable (spec decision 3: share-backed
  # libraries are current-state only; restore stays a chunk-mode feature).
  #
  # `nodes` is still the catalog — the scanner indexes into it — so browse/search/tags and the
  # maker layer work unmodified.
  class Share
    def initialize(root: ENV.fetch("LIBRARY_PATH"))
      @root = Pathname.new(root).expand_path
    end

    attr_reader :root

    def capabilities
      # No history (nothing to restore), no sync engine (web-only), nothing to presign (a
      # mounted directory has no URL signer). The UI reads this to hide Restore/History.
      #
      # scannable: true — the user drops files on the NAS in Finder, so the catalog can only be
      # learned by walking the root on a timer (Library::Scanner). This is the capability
      # Library::ScanJob.scan_all! gates on; before it, that gate was `is_a?(FileLayer::Share)`,
      # i.e. this very fact spelled as a class check, which is why it broke when S3 arrived.
      #
      # port_writable: true — there is no sync engine here, so the port IS the write path
      # (#write/#delete/#move/#undelete) and the UI POSTs bytes to it.
      Capabilities.new(versioned: false, syncable: false, presignable: false, scannable: true,
                       port_writable: true, dir_deletable: false)
    end

    def stat(user, node_id:)
      file_info(live_node!(user, node_id))
    end

    # ONE query for the whole list — see Chunk#stat_all, which argues why this is a port verb and
    # why a missing node is an absent key rather than a raise. Cheaper here than there only
    # because #stat is already answered from the node alone: there is no second lookup to batch,
    # so the N+1 this closes was N queries, not 2N (measured: 2000 queries / 271 ms at 2000
    # nodes). The share is NOT touched, for the reason #stat gives — a browse view must not put
    # a NAS round-trip behind every row.
    def stat_all(user, node_ids:)
      user.nodes.present.where(node_id: node_ids).to_h { |n| [ n.node_id, file_info(n) ] }
    end

    # What is in this deployment's trash: the files WE moved to `.trash/<node_id>/<name>`, which
    # `undelete` can move back. A read verb, so it is answered here even though it reports on the
    # write path's leavings.
    #
    # `storage_path: nil` IS THE FILTER, AND IT IS THE TWO-TOMBSTONE-KINDS DISTINCTION (2b
    # Landmine 2) BEING READ RATHER THAN A CLEVER PREDICATE. There are exactly two ways a node
    # here becomes deleted, and only one of them is a trash:
    #
    #   - a TRASH tombstone (`delete` above): the bytes are in `.trash` and storage_path is NULLED
    #     — precisely so a scan cannot revive it by path. `undelete` moves them back.
    #   - a SCAN tombstone (Reconciler): the user removed the file in Finder, so the bytes are
    #     GONE from storage we do not own, and the row KEEPS its storage_path (that is what lets a
    #     restored file revive its old node). `undelete` on one raises NotFound — there is nothing
    #     in `.trash` to move.
    #
    # So listing scan tombstones would offer a Restore button that cannot work. A row you can
    # never recover is not trash, it is history — and a share-backed library has no history (spec
    # §2 decision 4). Chunk mode filters nothing because there the two kinds do not exist.
    #
    # WHAT IT STILL CANNOT KNOW, stated so it is not read as a stronger promise than it is: a
    # trash tombstone whose bytes Library::TrashPurgeJob has already reclaimed still has a NULL
    # storage_path (the purge sweeps `.trash` by entry-dir mtime and deliberately never touches
    # the row), so it is listed and its Restore raises NotFound. Deciding otherwise would mean a
    # HEAD/stat per trashed node per page load, against a NAS, to catch a case the user is told
    # about honestly when they click. The filter is exact for the kind it names; it does not claim
    # the bytes are still there.
    def trashed(user)
      user.nodes.where(deleted: true, storage_path: nil).order(updated_at: :desc, name: :asc)
          .map do |n|
        TrashEntry.new(node_id: n.node_id, name: n.name, kind: n.kind,
                       size: n.size, deleted_at: n.updated_at)
      end
    end

    def read(user, node_id:, content_token: nil)
      node = live_node!(user, node_id)

      # Share keeps no history, so a token that isn't the current content is simply gone. This
      # must raise rather than silently serving current bytes: previews key on this token, so
      # answering with different content than was asked for is a correctness bug.
      if content_token.present? && content_token != node.content_hash
        raise NotFound, "content #{content_token.inspect} is not current (share keeps no history)"
      end

      path = absolute_path(node)
      size = File.size(path)
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if size > MAX_BYTES
      File.binread(path)
    rescue Errno::ENOENT => e
      # An unmounted share makes EVERY file vanish with ENOENT at once — indistinguishable from
      # "this one file was deleted" if we only look at the file. NotFound is terminal, so when
      # the whole library appears to have evaporated, prefer the retryable answer: a genuinely
      # emptied library retried is harmless, a live library burned to "failed" is not (spec §6).
      #
      # The deliberate trade-off: a user who really does empty their library gets FetchError
      # (retries, then gives up non-terminally) rather than NotFound. That is the safe
      # direction, and it is consistent with the scan's mass-deletion guard, which likewise
      # refuses to tombstone rather than believe a mass disappearance. Both ask "is the share
      # mounted?" rather than "did the user delete everything?".
      unless library_present?
        raise FetchError, "#{node_id.inspect}: ENOENT and the library root looks unmounted"
      end
      # The library is there and this one file isn't. Genuinely gone: terminal.
      raise NotFound, "#{node_id.inspect}: #{e.class}"
    rescue SystemCallError => e
      # EVERY other errno is transient — an unmounted NAS, a stale NFS handle, a permissions
      # blip. Fail SAFE rather than enumerate: NotFound (and any StandardError, which every
      # Errno is) burns a preview to a permanent "failed" in GeneratePreviewJob's `rescue
      # StandardError` branch, while FetchError is caught by its `retry_on` and backs off. We
      # cannot list every errno an SMB/NFS mount can produce — ENOTCONN, EHOSTDOWN, ENETDOWN,
      # ESTALE, EIO, ELOOP, ENOTDIR — so the DEFAULT must be the recoverable answer. Only
      # ENOENT can mean "genuinely deleted", so only ENOENT is terminal.
      raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
    end

    # Hand the browser this file's bytes — as a PATH, because there is nothing here to presign.
    # This is the backend where §15 ("keep bytes out of Rails") genuinely cannot hold: a mounted
    # directory has no URL signer, which is exactly what presignable: false records. Spec §9's
    # deliberate departure, scoped to storage we do not own. Do not "fix" it back.
    #
    # SendFile carries the path rather than the bytes, so the controller can hand it to send_file
    # and keep a 2GB file off the Rails heap (and let x_sendfile_header pass it to a proxy where
    # an operator has configured one).
    #
    # THROUGH #absolute_path, WHICH IS THE WHOLE POINT OF THIS METHOD BEING SHORT. Delivery::
    # SendFile is a Data object anyone can construct with anything, so the TYPE guarantees
    # nothing: this is the only thing standing between a poisoned storage_path and a controller
    # that will send_file whatever it is handed. The same choke point #read resolves through —
    # not a copy of it, because two copies of an escape guard drift and this file already makes
    # that argument for live_node!.
    #
    # `disposition:`/`content_type:` are the controller's policy and are applied THERE, by
    # send_file's own options. They are on the signature because S3's Redirect must sign them
    # into the URL at mint time (see Delivery); a transport that applies them later ignores them.
    #
    # `disposition:` is REQUIRED even though this adapter never reads it — the port's signature
    # is one signature, and a caller who may omit it here but not on S3 is a caller who learns
    # the rule from whichever backend they happened to develop against. See S3#download, where
    # omitting it silently produces a header with no disposition type at all.
    # THE EXISTENCE CHECK IS NOT DECORATION, and it is here rather than in the controller because
    # only this class can answer the question honestly. Without it a vanished file reaches
    # send_file, which raises ActionController::MissingFile — mapped to :internal_server_error
    # (verified: it has no rescue_response of its own), so an ordinary "the user deleted it on
    # the NAS" pages on-call as a 500.
    #
    # Mapping MissingFile to a 404 in the controller would fix that symptom and re-open the one
    # #read exists to prevent: an UNMOUNTED share makes every file vanish at once, and the
    # controller cannot tell that from a deletion — `library_present?` is this object's knowledge,
    # not the web layer's. So this reuses #read's exact reasoning: ENOENT + a library that looks
    # unmounted is the RETRYABLE answer, never the terminal one (spec §6). An unmounted NAS must
    # never read to a user as "your file is permanently gone".
    #
    # Known, accepted race: the file can vanish between this stat and send_file's open, which
    # degrades to the MissingFile 500 above. That is a genuine "it changed under us" — narrow and
    # honest — where the unchecked version made it the ORDINARY case.
    def download(user, node_id:, disposition:, content_type: nil)
      path = absolute_path(live_node!(user, node_id))
      File.stat(path) # raises; the rescues below map it exactly as #read does
      Delivery::SendFile.new(path: path.to_s)
    rescue Errno::ENOENT => e
      unless library_present?
        raise FetchError, "#{node_id.inspect}: ENOENT and the library root looks unmounted"
      end
      raise NotFound, "#{node_id.inspect}: #{e.class}"
    rescue SystemCallError => e
      # Every other errno is transient — see #read's argument, which applies here unchanged.
      raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
    end

    # Store new bytes at `name` under `parent_node_id` and index the result, so the node exists
    # the instant the caller can attach to it rather than up to a scan-interval later.
    #
    # NO TRANSACTION, deliberately: a filesystem write cannot be rolled back, so wrapping the
    # `create!` in one buys nothing and only widens the window in which the rename has landed but
    # the row has not. The failure it leaves — bytes on disk, no row, because `create!` raised —
    # is SELF-HEALING: the next scan indexes the file. (`delete` reaches the same conclusion by a
    # harder road — see the argument there, where a transaction would actively manufacture a
    # silent resurrection.)
    # `replace: true` — REPLACE THE CONTENT OF THE FILE ALREADY AT THIS PATH, reusing its node.
    # The opt-in the clobber refusal below is the DEFAULT for, and adding it does not weaken that:
    # every existing caller omits it and still gets the refusal. It exists for a door that has just
    # shown a user "this would replace design/x.svg — overwrite?" and been told yes.
    #
    # IT MUST REUSE THE NODE, NOT MINT ONE. A replace written as delete-then-create would look
    # right and orphan every attachment, BOM link and tag pointing at the file — §14a's recorded
    # landmine, whose signature is that nothing errors and nothing logs.
    #
    # THE DISK HALF IS ALREADY WRITTEN: File.rename over an existing destination is atomic on
    # POSIX, so the temp-then-rename below replaces safely with no change at all. Only this guard
    # and the indexing at the bottom differ.
    #
    # `replace: true` ON A VACANT PATH IS AN ORDINARY CREATE, deliberately — the caller is stating
    # intent about a collision, not asserting one exists, and a door that raced the file's deletion
    # should still write. The same is true when the bytes are there but unindexed: `existing` is
    # nil, a node is created, and that is exactly what the next scan would have done.
    def write(user, parent_node_id: nil, name: nil, io: nil, replace: false)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      dest = resolve_inside!(rel)
      existing = (user.nodes.present.find_by(storage_path: rel, kind: "file") if replace)
      raise UnsupportedOperation, "#{rel.inspect} already exists" if File.exist?(dest) && !replace

      bytes = read_capped!(io)
      FileUtils.mkdir_p(dest.dirname)
      # Temp-then-rename: the 15-minute scan may be walking this directory right now, and a
      # half-written file would be indexed with a hash of its own torn state. The rename is
      # atomic, and keeping the temp in the DESTINATION'S OWN directory is what makes it so —
      # a temp under `.trash/` (the one prefix the Scanner truly skips) would be invisible to a
      # racing scan, but renaming ACROSS directories raises EXDEV if the user has a second share
      # mounted inside their library, breaking every write into that subtree. Same-directory
      # rename cannot EXDEV, and it needs no answer to a question Task 3 has not settled yet.
      #
      # The Scanner skips this prefix at every depth — see Library::Scanner::TEMP_PREFIX, which
      # documents what happens when it doesn't: a scan landing inside the binwrite window indexes
      # the torn temp, the rename makes it vanish, its hash can never pair, and the resulting
      # tombstone trips the mass-deletion guard — refusing that scan and every scan after it,
      # permanently. Reproduced before that skip existed; do not inline the string here, because
      # two copies that must match exactly would bring the wedge back the moment they drift.
      tmp = dest.dirname.join("#{Library::Scanner::TEMP_PREFIX}#{SecureRandom.hex(8)}")
      begin
        File.binwrite(tmp, bytes)
        File.rename(tmp, dest)
      rescue SystemCallError => e
        FileUtils.rm_f(tmp)
        # Same reasoning as `read`'s rescue: a full NAS, a permissions blip, an unmounted share.
        # Every one of them is retryable, and NONE of them means "this file is gone".
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end

      # stat the DESTINATION after the rename — that is the mtime the next scan will stat, and
      # the scan-agreement test pins that these two agree exactly.
      st = File.stat(dest)
      attrs = { size: st.size, mtime: nanos(st), content_hash: Digest::SHA256.hexdigest(bytes) }
      node =
        if existing
          # UPDATE, so node_id survives (see the header). name/storage_path/parent are already
          # this file's — a replace resolves to the SAME rel — so only the content facts move.
          existing.update!(**attrs)
          existing
        else
          user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", deleted: false,
                             storage_path: rel, parent_node_id:, **attrs)
        end
      stat(user, node_id: node.node_id)
    end

    # THE OTHER HALF OF Chunk#write's REFUSAL (Task 8), mirrored — this backend is port_writable,
    # so its uploads go through #write above, all in one request; the sync engine's presigned
    # two-phase flow (begin a commit, PUT missing chunks, finalize) is meaningless for a plain
    # mounted directory, which has no chunk store to presign INTO. FilesController never reaches
    # this: begin_upload/finalize_upload are gated on `syncable`, which this backend answers false,
    # so the 501 a caller actually sees comes from that capability gate, before the call — never
    # from this raise. This exists anyway for the same reason Chunk#write does: a caller that
    # somehow reaches this class directly (a test, a future non-HTTP caller) gets a named, loud
    # refusal that says which door DOES work, rather than a NoMethodError that reads as an
    # oversight. ONE message, reused by both methods below, because they are one fact ("this
    # backend takes bytes through #write") tripped over from two different calls — the same
    # sharing #destination_vacant! already argues for, and Chunk::WRITE_MSG's own header explains
    # why sharing is fine for a fact but not for per-verb remediation advice; there is no per-verb
    # advice to diverge on here; both name the identical other door.
    TWO_PHASE_MSG = "#{name} is port_writable -- uploads go through #write (bytes arrive in one " \
                    "request), not the sync engine's two-phase presigned flow".freeze

    def begin_upload(_user, name: nil, size: nil, manifest: nil, device: nil, parent_node_id: nil,
                     node_id: nil, base_version_id: nil, mtime: nil, mode: nil)
      raise NotImplementedError, TWO_PHASE_MSG
    end

    def finalize_upload(_user, commit_id: nil, verify: true)
      raise NotImplementedError, TWO_PHASE_MSG
    end

    # Create ONE directory `name` under `parent_node_id` (nil = library root). Reuses write's exact
    # guards — leaf!/observable!/resolve_inside! — because a mkdir that skips them re-opens the
    # scan-wedge bug class this file documents (a live node at a path no scan can pair). Idempotent:
    # a live dir already at this rel is returned, not duplicated (Maker::LibraryFolder walks paths
    # and calls this repeatedly). The real directory is created on disk, so the next scan RECONCILES
    # the dir node by storage_path — that is what makes an EMPTY project folder survive, unlike a
    # bare dir-node insert (which the v1 mkdir 501 warns the scan would undo).
    def mkdir(user, parent_node_id: nil, name: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      existing = user.nodes.present.find_by(kind: "dir", storage_path: rel)
      return stat(user, node_id: existing.node_id) if existing

      dest = resolve_inside!(rel)
      raise UnsupportedOperation, "#{rel.inspect} already exists as a file" if dest.exist? && !dest.directory?
      begin
        FileUtils.mkdir_p(dest)
      rescue SystemCallError => e
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "dir", deleted: false,
        storage_path: rel, parent_node_id:, mtime: nanos(File.stat(dest))
      )
      stat(user, node_id: node.node_id)
    end

    # Move the file out of the indexed tree into `.trash/<node_id>/<name>` and tombstone the
    # node. Keyed by node_id, not name: two `bracket.stl` from different folders must not
    # collide, and Task 4's undelete needs one unambiguous place to look.
    #
    # NO TRANSACTION, and this is the one place in this file where that needs arguing rather
    # than asserting: `File.rename` is not transactional, so a `transaction do` around both
    # would roll back the ROW while leaving the FILE in `.trash` — manufacturing exactly the
    # silent resurrection the ordering below exists to avoid. `node.update!` is a single
    # statement and already atomic, which is the only atomicity this needs.
    def delete(user, node_id: nil)
      node = live_node!(user, node_id)
      deletable_file!(node)
      src = absolute_path(node) # read BEFORE the update nulls storage_path
      dest_dir = trash_dir(node.node_id)
      begin
        # mkdir_p is INSIDE the begin: it is I/O against the same share as the rename, and it
        # fails for the same transient reasons (a read-only mount, a full disk, an NFS perms
        # blip). Outside, its raw Errno escapes the SystemCallError -> FetchError mapping every
        # other I/O call in this file goes through, and a bare Errno IS a StandardError — which
        # is what burns a preview to a permanent "failed" instead of retrying. See read's rescue.
        FileUtils.mkdir_p(dest_dir)
        File.rename(src, dest_dir.join(node.name))
      rescue Errno::EXDEV => e
        # Do NOT fall back to copy+delete: that invents a half-state (bytes in two places, or
        # in neither) for an operation designed around an atomic rename. Spec §6 reserves
        # copy-then-tombstone for S3, which has no rename to lose. This is a real configuration
        # problem — a .trash symlinked elsewhere, a submount under the root — and it is the
        # operator's to fix, so say so and change nothing.
        discard_empty(dest_dir)
        raise FetchError, "#{node_id.inspect}: .trash is on a different filesystem (#{e.class}) " \
                          "— it must live under the library root"
      rescue SystemCallError => e
        # Same reasoning as read's and write's rescues: an unmounted NAS, a permissions blip.
        # Retryable, and none of them means "this file is gone".
        discard_empty(dest_dir)
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end

      # ORDER IS LOAD-BEARING, and it is the reverse of the intuitive one. Tombstone-then-move
      # leaves, if the move fails, a file the user cannot see and the next scan RESURRECTS (its
      # path is observed, so create_or_revive! finds the tombstone by storage_path and revives
      # it). Move-then-tombstone leaves, if the update fails, a file whose bytes are in .trash
      # and whose node is live at a path with nothing behind it — which reads as a vanished file
      # and is what the mass-deletion guard is for. The second failure is loud; the first is
      # silent.
      #
      # `deleted: true` is what keeps a UI delete out of the mass-deletion guard's numerator:
      # vanished_paths reads the `present` scope, so a tombstoned node is invisible to it and
      # deleting most of a library can never make the next scan refuse itself.
      #
      # `storage_path: nil` RELEASES the path, and is not merely tidy: Reconciler#create_or_revive!
      # revives a tombstone BY storage_path, so a trash tombstone that kept its path would hand a
      # NEW, unrelated file dropped there the trashed node's node_id — and with it every
      # attachment, BOM link and tag — while the old bytes sat in .trash waiting for an undelete
      # that would then collide. Nulling it is what makes that revive unable to fire.
      node.update!(deleted: true, storage_path: nil)
      nil
    end

    # Rename and/or re-parent a node, keeping its node_id — which is the port's whole promise, and
    # the reason this exists at all rather than leaving the user to do it in Finder and wait for a
    # scan to pair it back.
    #
    # DIRECTORIES ARE ALLOWED, and the asymmetry with `delete` is deliberate rather than an
    # oversight — see deletable_file!, which predicted it. A moved directory leaves its children's
    # bytes OBSERVABLE at the new path, so the Reconciler's move-pairing re-homes them on the next
    # pass with their node_ids intact (probed: 2/2 children re-homed, no ghosts, and the
    # mass-deletion guard does not fire because it counts the POST-pairing set). A DELETED
    # directory puts them in .trash, where the scan refuses to look, so nothing can ever pair them
    # — a permanent wedge. Observable vs. skipped is the entire difference.
    #
    # Only the moved node's own row is rewritten, so a moved directory's descendants keep a STALE
    # storage_path until the next scan. Two residuals follow, and both are accepted because they
    # are EXACTLY what the user renaming that folder in Finder already produces — the case this
    # phase is built to survive:
    #   1. reads of a descendant ENOENT until the scan re-homes it (its parent_node_id is NOT
    #      stale — the dir kept its node_id — so browse never breaks; only bytes do).
    #   2. the repair pass re-hashes the whole moved subtree (pairing has nothing else to match
    #      on), and a descendant that is unreadable at that moment cannot be paired, so it
    #      tombstones and re-creates with a new node_id, orphaning its attachments.
    # Cascading the prefix rewrite to descendants here would close both. It is the right end
    # state and it is NOT in this phase's plan — left as a deliberate decision rather than
    # smuggled in, since it is the first thing in this adapter that would write rows for paths
    # the op did not observe.
    #
    # NO TRANSACTION, for the reason the whole file gives: File.rename is not transactional, so a
    # rollback would restore the ROW while leaving the FILE moved — the worse of the two states.
    def move(user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      leaf!(new_name)
      node = live_node!(user, node_id)
      src = absolute_path(node)
      rel = join_rel(parent_dir_rel!(user, new_parent_node_id), new_name)
      observable!(rel)
      dest = resolve_inside!(rel)
      # Refuse rather than replace. POSIX rename() would silently clobber, and the maker layer has
      # no undo for it: the displaced file's node would still point at a path now holding someone
      # else's bytes. (fs-provider's rename DOES replace — it is implementing POSIX for a kernel
      # mount. This is a UI operation, and refusing is the honest answer to a user's typo.)
      #
      # dest == src IS NOT A CLOBBER — it is this node's OWN current file, found because a no-op
      # move (same folder, same name) resolves to the identical destination. File.exist?(dest)
      # cannot tell "someone else already lives here" from "I am already here"; comparing the
      # resolved paths can, since both come through the same resolve_inside! and a live path is
      # unique to one node. Found by Task 4's mutation-contract companion test in
      # adapter_mutation_contract.rb (the "onto its own current name is not a collision" one), run
      # against this adapter UNMODIFIED per the contract's own rule that a no-op move must stay
      # legal on every backend — this adapter had never made that exclusion. Not reachable from
      # either production caller today (Maker::AttachToProject#move short-circuits on
      # `:already_there` before calling in; Maker::ProjectIntake#place only ever targets a
      # project's ROOT, never its own destination folder) — latent, not live, but a port verb
      # should not depend on its callers to avoid its own gaps.
      raise UnsupportedOperation, "#{rel.inspect} already exists" if dest != src && File.exist?(dest)

      begin
        # mkdir_p INSIDE the begin, exactly as in delete: it is I/O against the same share and
        # fails for the same transient reasons, and outside, its raw Errno escapes the
        # SystemCallError -> FetchError mapping and burns a preview to a permanent "failed".
        FileUtils.mkdir_p(dest.dirname)
        File.rename(src, dest)
      rescue SystemCallError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end
      # The node_id does not change — that is the port's whole promise, and the write contract
      # (Task 5) pins it as a cross-backend rule.
      #
      # KNOWN API AMBIGUITY: `new_parent_node_id: nil` means THE ROOT, so this cannot distinguish
      # "rename in place" from "move to the root" — a caller who omits it while meaning a rename
      # moves the file to the top of the library. The port's signature is what it is (Task 5 pins
      # it); a caller renaming must pass the current parent_node_id. Stated here because the
      # failure is silent and the fix is one keyword at the call site.
      node.update!(storage_path: rel, name: new_name, parent_node_id: new_parent_node_id)
      stat(user, node_id: node.node_id)
    end

    # Move the bytes back out of .trash and revive the node — the inverse of `delete`, and the
    # mirror of the structural hazard that shapes it. delete moves bytes INTO a region the Scanner
    # skips, which is what makes its ghosts unpairable; undelete moves them OUT, which is the safe
    # direction: the path becomes observable and the node becomes live together, so the next scan
    # simply matches it by path.
    #
    # ORDER — move, then revive — is the same trade delete makes, resolved the same way. Revive
    # first and a failed move leaves a live node pointing at nothing while its bytes sit in .trash:
    # unobservable, unpairable, the ghost class itself. Move first and a failed revive leaves the
    # bytes at their real path with the node still trashed — which the next scan simply INDEXES,
    # so the user's file is visibly back (it loses its old node_id, but nothing is lost or hidden).
    # Loud and self-healing beats silent.
    #
    # (That same scan, landing inside this method's own move->revive window, is a real but narrow
    # race: it creates a node for the observed path, and this update! then collides with the
    # partial unique index on (user_id, storage_path) WHERE deleted = false. The result is a raw
    # RecordNotUnique out of a file the user can see and use, under a new node_id. Recorded rather
    # than fixed: every ordering that closes it opens the strictly worse one above.)
    def undelete(user, node_id: nil)
      # NOT live_node!: this operates on a tombstone by definition. `deleted: true` in the lookup
      # is what makes undeleting a live node a clean NotFound instead of a confusing rename.
      node = user.nodes.find_by(node_id:, deleted: true) ||
             raise(NotFound, "node #{node_id.inspect} is not in the trash")
      src = trash_dir(node.node_id).join(node.name)
      unless File.exist?(src)
        # An UNMOUNTED share makes the trashed bytes absent too — and this is the only place
        # besides `read` where this adapter mints a "your file is gone". It must ask the same
        # question, for the same reason: NotFound is TERMINAL, so answering it while the NAS is
        # merely down tells the user their file is permanently lost when it is sitting safely on
        # the share. See read's rescue for the full argument; the trade is identical.
        unless library_present?
          raise FetchError, "#{node_id.inspect}: the trashed bytes are missing and the library " \
                            "root looks unmounted"
        end
        # The library is there and the bytes are not. The purge job (Task 6) took them, or this is
        # a SCAN tombstone, which never had bytes in .trash to begin with. Both are terminal and
        # both are the user's answer: it is gone.
        raise NotFound, "#{node_id.inspect}: its trashed bytes are gone (purged?)"
      end

      # Reconstructed from parent + name, because delete released storage_path (Landmine 2).
      # live: false — see parent_dir_rel!.
      rel = join_rel(parent_dir_rel!(user, node.parent_node_id, live: false), node.name)
      # THE FOURTH INSTANCE OF THE SKIP-LIST BLIND SPOT, and it was reported as unreachable, which
      # was wrong. `rel` is reconstructed from the PARENT, so a parent whose storage_path is
      # `.maker-tmp-evil` restores the file to `.maker-tmp-evil/a.stl`: a live node at a path the
      # Scanner skips at any depth -> an observation can never partner it -> an unpairable ghost ->
      # a tombstone -> the mass-deletion guard refuses that scan and every scan after it. Probed,
      # via the same poisoned-row standard (update_column) the escape-guard tests use.
      #
      # S3#undelete has had this since Phase 3; this is the divergence, not a new rule. Every
      # writing path here now asks -- write, move, and undelete -- which is the structural finding
      # rather than three coincidences: assume every path that writes is exposed until checked.
      observable!(rel)
      dest = resolve_inside!(rel)
      if File.exist?(dest)
        raise UnsupportedOperation, "#{rel.inspect} is occupied — undelete must not clobber"
      end

      begin
        FileUtils.mkdir_p(dest.dirname) # inside the begin, for the reason move and delete give
        File.rename(src, dest)
      rescue SystemCallError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end
      discard_empty(trash_dir(node.node_id))
      # Re-stat: the bytes are the same, but mtime/size are what the next scan compares against,
      # and a stale pair would make it re-hash the file for nothing.
      st = File.stat(dest)
      node.update!(deleted: false, storage_path: rel, size: st.size, mtime: nanos(st))
      stat(user, node_id: node.node_id)
    end

    # Resolve a node's path and refuse anything that escapes the root. Belt and braces: paths
    # come from our own scanner, but the audit that preceded this work found exactly this bug
    # class in client-supplied chunk hashes used as storage keys.
    #
    # Public because it is a resolution utility rather than a read-path internal: the escape
    # guard is worth exercising directly (no `send`), and the scanner/reconciler in Tasks 5-6
    # resolve the same node -> path mapping against the same root.
    #
    # A BLANK storage_path IS NOT A PATH, and refusing it here is the whole method. `@root.join("")`
    # is the ROOT, so this used to hand a live NULL-path node's DIRECTORY back as its file: #read
    # got EISDIR (an accident that reads as FetchError) and #download -- which does not read, it
    # answers Delivery::SendFile(path:) -- handed the controller the library root to send_file.
    # `delete`/`move` escaped only by accident too (EINVAL from renaming a dir into itself). The
    # accidents are not the guard; this is. S3#key_for has had exactly this check since Phase 3,
    # and closing the asymmetry is the point.
    #
    # Reachable by DATA, not by a caller: on share every producer of a live NULL-path node is
    # 501-gated as of Phase 4, so the gates are what make it unreachable rather than this adapter.
    # A DB flipped chunk->share reaches it directly -- chunk nodes never carry a storage_path.
    #
    # THE `allow_root:` LATITUDE IS GONE WITH IT, so this is now resolve_inside! plus the blank
    # check. It was justified as "a read may resolve to the root itself (harmless -- File.binread
    # of a directory is EISDIR anyway)", and Phase 4's #download is what made that false: SendFile
    # never reads. Nothing legitimate wanted it -- the ONLY storage_path values that resolve to the
    # root are blank, "." and "a/..", none of which any producer writes and none of which is a file.
    def absolute_path(node)
      rel = node.storage_path.to_s
      raise NotFound, "node #{node.node_id.inspect} has no storage_path" if rel.blank?
      resolve_inside!(rel)
    end

    private

    # Derivable from the node alone — no column. Library::Scanner::TRASH_PREFIX rather than a
    # second ".trash" literal: the Scanner's skip and this layout are the SAME fact, and two
    # copies of it is how the trash quietly starts getting indexed. (write's temp prefix makes
    # the identical argument, for the identical reason.)
    def trash_dir(node_id) = @root.join(Library::Scanner::TRASH_PREFIX, node_id)

    # Deleting a DIRECTORY is refused rather than cascaded. File.rename on a directory succeeds,
    # so without this check `delete` would move a whole subtree into .trash while leaving every
    # child node live at a path that no longer exists — the next scan finds them all vanished,
    # cannot pair them (their bytes are in .trash, which the scan skips), and refuses itself via
    # the mass-deletion guard once that subtree is >20% of the library. Nothing then clears the
    # ghosts, so the refusal is permanent: Task 2's temp-file wedge by another road.
    #
    # That is an instance of a STRUCTURAL property, not a coincidence: wherever this app moves
    # bytes INTO a region the Scanner skips (.trash, .maker-tmp-) while leaving a live node
    # pointing at the old path, it creates ghosts the Reconciler can never pair — pairing needs
    # an OBSERVATION as the partner, and a skipped path produces none.
    #
    # An earlier draft of this paragraph concluded "delete is uniquely exposed, because a dir MOVE
    # leaves the bytes observable at the new path while a dir DELETE puts them where the scan
    # refuses to look." The principle was right and the conclusion was FALSE, which is worth
    # leaving here as a warning: a move is only self-healing when its DESTINATION is observable,
    # and `write`/`move` used to accept `.trash` and `.maker-tmp-x` as destinations — perfectly
    # good leaf names — wedging the library the same way, and additionally breaking every delete
    # in it by turning `.trash` into a file. See `observable!`, which is the guard that claim's
    # confidence delayed. The property is structural; assume every path that writes is exposed
    # until you have checked it, and do not trust a sentence like the one this replaced.
    #
    # Chunk mode cascades instead (Sync::SubtreeDelete, whole subtree under one lock). Share mode
    # deliberately does not: 2b is file-only, `undelete` restores ONE path under ONE parent and
    # has no subtree story, and a cascade whose inverse does not exist is a delete the user cannot
    # undo. (Worked both ways and both collapse: nulling the children's paths makes undelete mint
    # new node_ids and lose every attachment; keeping them reintroduces the revive-by-path bug for
    # each child.)
    #
    # Named for DELETE, not for `kind`, though it looks op-agnostic: Task 4's `move` may want a
    # kind check too, and its answer is likely DIFFERENT (a moved dir's bytes stay observable, so
    # the scan repairs the children on the next pass — a self-healing inconsistency, not a wedge).
    # Sharing one guard would make this message lie there. Task 4 gets its own decision.
    def deletable_file!(node)
      return if node.file?
      # UnsupportedOperation, not NotImplementedError: a user clicked delete on a folder, so this is a
      # CLIENT condition (Phase 4 -> 409/422), and it must stay catchable by `rescue StandardError`.
      # NotImplementedError is a ScriptError and means the DEPLOYMENT is mis-wired -> 501.
      raise UnsupportedOperation,
            "#{node.node_id.inspect} is a #{node.kind}: share-mode delete is files only — " \
            "deleting a directory would strand its children's nodes at paths that no longer " \
            "exist and wedge the next scan"
    end

    # Undo the entry dir when the move it was made for never landed, mirroring write's rm_f of
    # its temp: rmdir only ever removes an EMPTY directory, so it cannot take bytes with it.
    def discard_empty(dir)
      FileUtils.rmdir(dir)
    rescue SystemCallError
      nil # non-empty or already gone; the purge job (Task 6) sweeps it either way
    end

    # THE guard, for reads and writes alike: the resolved path must be STRICTLY inside the root.
    # One mode, because neither door has a use for the root itself — a write to it would be a write
    # to the library directory as a file, and a read of it is the hole #absolute_path now closes.
    # (It took an `allow_root:` parameter until that fix, on the read path's behalf; the parameter
    # is gone rather than left switched off, so there is nothing to switch back on.)
    def resolve_inside!(rel)
      path = @root.join(rel.to_s).expand_path
      # start_with?("#{@root}/"), never start_with?(@root): a SIBLING directory whose name merely
      # has the root as a prefix would otherwise pass.
      unless path.to_s.start_with?("#{@root}/")
        raise NotFound, "path escapes the library root: #{rel.inspect}"
      end
      path
    end

    # A leaf name is a leaf. `.` and `..` are separator-free, so File.basename passes them — they
    # need naming explicitly, and refusing them here is what makes it true that no `name` value
    # can reach the escape guard.
    def leaf!(name)
      return unless name.blank? || File.basename(name.to_s) != name.to_s || %w[. ..].include?(name.to_s)
      raise NotFound, "#{name.inspect} is not a leaf name (the directory is parent_node_id's job)"
    end

    # The write path must never create a path the Scanner SKIPS. `leaf!` asks a different
    # question — "is this one path segment?" — and a reserved name passes it: `.trash` and
    # `.maker-tmp-x` are perfectly good leaves.
    #
    # This is the FOURTH instance of the skip-list blind spot, and the worst, because it wedges
    # twice. Reproduced: `write(name: ".trash")` is one upload of an ordinary-looking file, and
    #
    #   1. it creates a live node at a path the scan never observes -> unpairable -> tombstoned
    #      -> the mass-deletion guard refuses that scan and EVERY SCAN AFTER IT (the ghost class
    #      Library::Scanner::TEMP_PREFIX documents at length); and
    #   2. `.trash` is now a FILE, so #delete's mkdir_p raises EEXIST and EVERY DELETE IN THE
    #      LIBRARY breaks — permanently, and not fixed by clearing the ghost. Someone has to
    #      remove the file on the NAS by hand.
    #
    # Nobody wrote this bug; four correct pieces grew into it. 2a shipped TRASH_PREFIX; `leaf!`
    # was written as a leaf check; the temp-file fix grew the skip-list into a RESERVED-NAME list
    # without telling the validator; `move` then inherited `leaf!` unexamined. The lesson for
    # whoever adds the next skipped prefix: the Scanner's skip-list and this guard are one fact,
    # so they share the constants rather than a copy of the strings.
    #
    # Checked on `rel`, not `name`: the parent contributes segments too. Root-anchored for
    # .trash and any-depth for the temp prefix, matching Scanner#each_child exactly — a nested
    # `cad/.trash` is the user's own folder, is indexed, and is none of our business.
    def observable!(rel)
      segments = rel.to_s.split("/")
      # OS clutter (.DS_Store, ._*, __MACOSX/, macOS volume metadata) joined the unobservable set
      # the moment the observers began skipping it — so a write/move/undelete onto one of these
      # names is the same wedge `.trash` was: a live node at a path no scan can pair. The reject
      # predicate is the SAME Library::OsClutter the observers skip on (see that module).
      return unless segments.first == Library::Scanner::TRASH_PREFIX ||
                    segments.any? { |s| s.start_with?(Library::Scanner::TEMP_PREFIX) } ||
                    Library::OsClutter.ignore?(rel)
      raise NotFound, "#{rel.inspect} is a reserved path the library scan does not index"
    end

    def join_rel(dir_rel, name) = dir_rel.blank? ? name.to_s : "#{dir_rel}/#{name}"

    # Blank means THE ROOT — join_rel turns a nil dir into a bare name. That convention is what
    # lets `parent_node_id: nil` be a real destination, and it is also why the path-less guard
    # below is not paranoia.
    #
    # `live: false` relaxes the lookup to include TOMBSTONED directories, and it exists for
    # `undelete` alone. The route is not the one it looks like: an emptied directory still exists
    # on disk, so a scan observes it and never tombstones it (probed). But if the user then
    # removes the empty folder in Finder, THAT scan tombstones the dir node — keeping its
    # storage_path — and the file trashed out of it is still perfectly restorable. Refusing it
    # would be a dead end the user can neither see nor fix, for a folder they are in the middle of
    # restoring a file into; mkdir_p recreates the folder instead, and because a recreated folder
    # is positive evidence, the next scan revives that very dir node by storage_path with its
    # original node_id. Self-healing, and pinned.
    #
    # The WRITE path keeps live: true, and that asymmetry is the point: writing a NEW file into a
    # folder the user deleted is a request to reconsider, while restoring a file that was already
    # in there is a request to undo.
    def parent_dir_rel!(user, parent_node_id, live: true)
      return nil if parent_node_id.blank?
      scope = live ? user.nodes.present : user.nodes
      parent = scope.find_by(node_id: parent_node_id, kind: "dir") ||
               raise(NotFound, "parent #{parent_node_id.inspect} is not a " \
                               "#{'live ' if live}directory")
      # A dir node cannot carry a nil storage_path today — delete refuses directories, and a scan
      # tombstone keeps its path — so this is unreachable. It is here because of what happens if
      # that ever stops being true: blank means the root, so a path-less parent would silently
      # relocate the file to the top of the library rather than fail. Of everything this adapter
      # can get wrong, a silent misplacement is the one it has no later way to detect.
      raise NotFound, "parent #{parent_node_id.inspect} has no storage_path" if parent.storage_path.blank?
      parent.storage_path
    end

    # Read the cap PLUS ONE byte: reading exactly MAX_BYTES cannot distinguish "exactly at the
    # cap" from "truncated at the cap", so an oversize upload would be silently cut in half and
    # stored as a valid-looking file. Reads at most 256MB+1 into memory, which is the same
    # exposure `read` already accepts (and the same constant caps it).
    def read_capped!(io)
      bytes = io.read(MAX_BYTES + 1).to_s.b
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
      bytes
    end

    # Duplicated from Library::Scanner#nanos deliberately: this is the exact formula the scan will
    # compare against, and the write path must not depend on the indexer to say what time it is.
    def nanos(st) = st.mtime.to_i * 1_000_000_000 + st.mtime.nsec

    # Is the share actually mounted? Emptiness is the signal: an unmounted mount point is a
    # real, readable, EMPTY directory (File.exist? returns true for it, which is why that check
    # is not enough).
    #
    # Dir.each_child with a break, not Pathname#each_child.any?: the latter delegates to
    # #children, which materializes the whole listing via Dir.entries before `any?` sees the
    # first element — measured 262x slower on a 20k-entry directory. This one stops at entry 1.
    # Cheap either way (ENOENT is rare), but the lazy form is free.
    #
    # KNOWN LIMITATION: a stale dotfile (.DS_Store) left on the underlying mount point by a
    # previous mount reads as "mounted", so this heuristic fails in the terminal direction for
    # that case. Counting dotfiles as content is still the right default — a mounted share
    # legitimately full of only dotfiles must not read as unmounted. The st_dev-vs-parent
    # mountpoint test would be exact, but LIBRARY_PATH may be a SUBDIRECTORY of the mount, where
    # st_dev always matches the parent and every read would look unmounted.
    def library_present?
      return false unless @root.directory?
      Dir.each_child(@root.to_s) { return true }
      false
    rescue SystemCallError
      # Can't even list the root: definitely not a healthy library. Retryable.
      false
    end

    # The liveness guard both stat and read must apply — a tombstoned node is GONE on every
    # backend (contract: test_contract_read_raises_not_found_for_a_deleted_node). Share
    # implements the same port as Chunk but does not inherit from it: they are independent
    # implementations, and a shared base class would be the one place chunk assumptions could
    # leak back into the port the split exists to keep clean. Three duplicated lines is the
    # cheaper trade.
    def live_node!(user, node_id)
      user.nodes.present.find_by(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} is deleted or does not exist")
    end

    # The one place a node becomes a FileInfo, shared by stat and stat_all — the browse view and
    # the detail view answering differently about the same file is the §9a-1 bug in a new
    # spelling, and one copy is what makes that impossible rather than unlikely. Duplicated in
    # S3#file_info rather than shared with it, which is this adapter's standing trade (live_node!,
    # leaf!, join_rel, nanos all make it); the READ CONTRACT is what keeps the two answers equal.
    def file_info(node)
      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.size.to_i,
        mtime: node.mtime,
        content_token: node.content_hash
      )
    end
  end
end
