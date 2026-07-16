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
      Capabilities.new(versioned: false, syncable: false, presignable: false)
    end

    def stat(user, node_id:)
      node = live_node!(user, node_id)
      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.size.to_i,
        mtime: node.mtime,
        content_token: node.content_hash
      )
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

    # Store new bytes at `name` under `parent_node_id` and index the result, so the node exists
    # the instant the caller can attach to it rather than up to a scan-interval later.
    #
    # NO TRANSACTION, deliberately, and unlike Task 3's delete: a filesystem write cannot be
    # rolled back, so wrapping the `create!` in one buys nothing and only widens the window in
    # which the rename has landed but the row has not. The failure it leaves — bytes on disk, no
    # row, because `create!` raised — is SELF-HEALING: the next scan indexes the file. (Task 3's
    # is not, which is why only Task 3 gets one.)
    def write(user, parent_node_id: nil, name: nil, io: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      dest = resolve_inside!(rel)
      raise NotFound, "#{rel.inspect} already exists" if File.exist?(dest)

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
      # KNOWN, NARROW: the Scanner skips `.trash` by name and invalid-encoding names — NOT
      # dotfiles — so a scan landing between the binwrite and the rename does index the temp.
      # The window is one binwrite (real for a large CAD file) and the outcomes are loud, not
      # lossy: a torn hash makes the ghost node unpairable (tombstoned next pass, or an
      # UnsafeScan on a small library), and a complete hash makes it pair with `dest` as a move
      # and collide with the create! below on the storage_path unique index. The real fix is a
      # temp-prefix skip in Library::Scanner, which this task's scope does not reach; flagged for
      # the task that owns the scanner/write-path interaction.
      tmp = dest.dirname.join(".maker-tmp-#{SecureRandom.hex(8)}")
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
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "file", deleted: false,
        storage_path: rel, parent_node_id:,
        size: st.size, mtime: nanos(st), content_hash: Digest::SHA256.hexdigest(bytes)
      )
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
    # `allow_root:` is the ONLY thing separating this from the write path's resolve_inside!, so
    # both delegate to one #resolve! rather than keeping two near-copies of the guard. Two copies
    # of a security check drift, and this file already makes that argument for live_node!.
    def absolute_path(node) = resolve!(node.storage_path, allow_root: true)

    private

    # The write path's guard: the destination must be STRICTLY inside the root. A read may resolve
    # to the root itself (harmless — it can only ever be handed a file node, and File.binread of a
    # directory is EISDIR anyway); a write to the root itself would be a write to the library
    # directory as a file, so it does not get the same latitude.
    def resolve_inside!(rel) = resolve!(rel, allow_root: false)

    def resolve!(rel, allow_root:)
      path = @root.join(rel.to_s).expand_path
      # start_with?("#{@root}/"), never start_with?(@root): a SIBLING directory whose name merely
      # has the root as a prefix would otherwise pass.
      inside = path.to_s.start_with?("#{@root}/") || (allow_root && path.to_s == @root.to_s)
      raise NotFound, "path escapes the library root: #{rel.inspect}" unless inside
      path
    end

    # A leaf name is a leaf. `.` and `..` are separator-free, so File.basename passes them — they
    # need naming explicitly, and refusing them here is what makes it true that no `name` value
    # can reach the escape guard.
    def leaf!(name)
      return unless name.blank? || File.basename(name.to_s) != name.to_s || %w[. ..].include?(name.to_s)
      raise NotFound, "#{name.inspect} is not a leaf name (the directory is parent_node_id's job)"
    end

    def join_rel(dir_rel, name) = dir_rel.blank? ? name.to_s : "#{dir_rel}/#{name}"

    def parent_dir_rel!(user, parent_node_id)
      return nil if parent_node_id.blank?
      parent = user.nodes.present.find_by(node_id: parent_node_id, kind: "dir") ||
               raise(NotFound, "parent #{parent_node_id.inspect} is not a live directory")
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
  end
end
