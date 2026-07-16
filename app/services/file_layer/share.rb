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

    # Resolve a node's path and refuse anything that escapes the root. Belt and braces: paths
    # come from our own scanner, but the audit that preceded this work found exactly this bug
    # class in client-supplied chunk hashes used as storage keys.
    #
    # Public because it is a resolution utility rather than a read-path internal: the escape
    # guard is worth exercising directly (no `send`), and the scanner/reconciler in Tasks 5-6
    # resolve the same node -> path mapping against the same root.
    def absolute_path(node)
      path = @root.join(node.storage_path.to_s).expand_path
      unless path.to_s == @root.to_s || path.to_s.start_with?("#{@root}/")
        raise NotFound, "path escapes the library root: #{node.storage_path.inspect}"
      end
      path
    end

    private

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
