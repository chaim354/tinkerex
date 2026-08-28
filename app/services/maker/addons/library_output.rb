require "digest"
require "stringio"

module Maker
  module Addons
    # THE ONE generic write path for addon output. An addon hands over a SET of files of ANY type;
    # each is written into the file library through the existing FileLayer machinery and tied to
    # `state` as an AddonFile with its role. The helper never inspects the bytes. Backend-neutral:
    #   - share/s3 (port_writable): FileLayer#write (bytes -> file/object).
    #   - chunk / chunk_remote (syncable): a single-chunk FileLayer#begin_upload/#put_chunk/
    #                              #finalize_upload — three port verbs wrapping the same two-phase
    #                              commit flow the web uploader drives, driven server-side (the
    #                              bytes are generated here — there is no client to presign for;
    #                              §15 is aimed at client uploads, and there is no client here). See
    #                              #write_chunk for why `#put_chunk` is a port verb rather than a
    #                              parameter on `#begin_upload` or a direct chunk-store call — it
    #                              used to be the latter (CLAUDE.md §14c's one sanctioned
    #                              chunk-internals reference), until that call turned out to be a
    #                              `NameError` on any deployment not loading the sync engine, which
    #                              `chunk_remote` (Arc B) is.
    # Writes to `parent_node_id` (default: root) with the caller's names, and CREATES — the
    # AddonFile join is the tie. A file may override BOTH of those: its own `parent_node_id`, and
    # `replace: true` to rewrite what is already at that name instead of refusing. Both default to
    # the original behaviour; see #write for why each exists. (This header used to say "writes FLAT
    # ... and CREATES (no clobber/versioning)", which was true of v1 and is no longer.)
    module LibraryOutput
      module_function

      # files: [{ name:, bytes:, content_type:, role:, parent_node_id?, replace? }].
      # Returns this save's AddonFiles — created, or UPDATED IN PLACE where a replace kept the node
      # and the state already had a row for it (see #upsert_file!). Not "the created AddonFiles",
      # which is what this line said while the door only ever created.
      #
      # TWO PER-FILE OPTIONS, both defaulting to today's behaviour so no existing caller changes:
      #
      #   parent_node_id — this file's own destination, overriding the call's. Needed because ONE
      #                    save can collide on some outputs and not others: the boxes addon emits
      #                    `<base>.svg` and `<base>-plan.svg` together, and a re-save can find the
      #                    first name taken in its category folder and the second free. `fetch`
      #                    rather than `||`, so an explicit `parent_node_id: nil` (the library
      #                    ROOT) is honoured instead of silently falling back to the default.
      #   replace        — rewrite the file already at that name, KEEPING ITS NODE. See #write_chunk
      #                    and FileLayer::Share#write for the two mechanisms and why node_id
      #                    survival is the whole point.
      #
      # WHICH FOLDER A NAME BELONGS IN IS NOT DECIDED HERE. That is project policy
      # (Maker::ProjectFolders), resolved by the door; this class is the backend-neutral WRITE
      # path and never inspects the bytes — it must not start inspecting the names either.
      def write(user:, state:, parent_node_id:, files:)
        files.each_with_index.map do |f, i|
          dest = f.fetch(:parent_node_id, parent_node_id)
          replace = f[:replace].present?
          node_id = write_bytes!(user, parent_node_id: dest, name: f[:name], bytes: f[:bytes], replace:)
          enqueue_preview(user, node_id, f[:name])
          upsert_file!(state, node_id:, role: f[:role], content_type: f[:content_type], position: i)
        end
      end

      # THE ONE port_writable? BRANCH, callable by a non-addon door. §14d counts these; this
      # extraction keeps the count at ONE rather than adding a sixth copy. An addon save and an
      # editor save are the same operation seen twice — server-side bytes into a library file,
      # replacing what is there, REUSING THE NODE — and the only difference is that an addon save
      # additionally records a maker_addon_files row.
      #
      # NAMED `write_bytes!` RATHER THAN `write` because the sibling `write` above takes a whole
      # addon save and returns rows. Two methods called `write` on one class, with different
      # arities and different return types, is the drift this repo names services to end.
      #
      # THE EXTRACTION IS IN PLACE AND THE CLASS DID NOT MOVE. docs/invariants/addons.md says in as
      # many words that this is the ONE output path; relocating it to suit a second caller would
      # put that claim and §14d's count in question to save an awkward namespace. The second caller
      # is recorded there instead — an invariant that silently acquires an exception is worse than
      # one that names it.
      def write_bytes!(user, parent_node_id:, name:, bytes:, replace: false)
        f = { name:, bytes: }
        caps = FileLayer.current.capabilities
        caps.port_writable? ? write_port(user, parent_node_id, f, replace) : write_chunk(user, parent_node_id, f, replace)
      end

      # UPSERT, NOT CREATE, BECAUSE A REPLACE KEEPS THE NODE. `maker_addon_files` is unique on
      # [addon_state_id, node_id], so a second save AGAINST THE SAME STATE — a revision, which
      # rewrites the same node in place — hands this method a node the state already has a row for,
      # and `create!` there is a bare ActiveRecord::RecordNotUnique 500 rather than any refusal
      # somebody designed. Identical behaviour for a first save, and for every save that creates a
      # new state: there is no row, so this creates one.
      #
      # A ROW WHOSE FILE THE BUNDLE STOPPED EMITTING IS LEFT ALONE, deliberately. That file is
      # still an ordinary library file the user may have renamed, attached to a project or put in a
      # BOM, and "a migration must not delete user bytes" (§14c) binds a save door too — the row is
      # the only record that this state produced it.
      #
      # THE COST, STATED PROPERLY: `position` IS NOW ONLY UNIQUE WITHIN ONE SAVE, AND NOTHING ON
      # THE ROW SAYS WHICH SAVE THAT WAS. A revision emitting a differently-named file leaves the
      # old row at position 0 and writes a new one at position 0 — verified, two rows, both zero —
      # so the relative order of a stale row and a current one is arbitrary and unrecoverable.
      # Maker::AddonState orders by (position, id) so at least the JSON #states hands a bundle is
      # stable request to request; that is a tiebreak, not a repair.
      def upsert_file!(state, node_id:, role:, content_type:, position:)
        row = state.files.find_or_initialize_by(node_id:)
        row.update!(role:, content_type:, position:)
        row
      end

      # The live file already at (parent, name), or nil — what a replace rewrites. Shared by both
      # doors below so they cannot disagree about which file "the one at that name" is.
      #
      # `kind: "file"` IS LOAD-BEARING, NOT A TIDY FILTER, and it is the only reason
      # FileLayer::Chunk#finalize_upload can leave Sync::Commit::KindConflict unrescued. Drop it
      # and a DIRECTORY at that name gets reused as this save's node_id; Sync::Commit then refuses
      # to change an existing node's kind and raises KindConflict -- a bare StandardError that
      # Tools::AddonsController's rescue_from arms (UnsupportedOperation / FetchError / NotFound)
      # do not name, so the user gets an unhandled 500 where the device-sync side answers a clean
      # 409 (V1::BaseController rescues it by name). Pinned by a regression test rather than left
      # to this comment, because the scope is one word and reads like housekeeping.
      def existing_at(user, parent_node_id, name)
        user.nodes.present.find_by(parent_node_id:, name:, kind: "file")
      end

      # --- share / s3 -----------------------------------------------------------
      def write_port(user, parent_node_id, f, replace = false)
        info = FileLayer.current.write(user, parent_node_id:, name: f[:name],
                                       io: StringIO.new(f[:bytes].b), replace:)
        info.node_id
      end

      # --- chunk / chunk_remote: single-chunk two-phase commit, driven server-side ------------
      #
      # A REPLACE HERE IS JUST A NEW VERSION, which is what versioning is FOR — commit against the
      # existing node_id with its current version as `base_version_id`, and the sync engine treats
      # it as the ordinary fast-forward it is (§6: a base that IS current is a clean fast-forward;
      # a stale one becomes a recorded conflict rather than a silent drop). So chunk needs no port
      # WRITE involvement at all (FileLayer::Chunk#write still refuses, unmoved), and unlike
      # share/s3 the old bytes stay restorable.
      #
      # THE BYTES GO THROUGH `#put_chunk`, A PORT VERB — NOT THROUGH A DIRECT
      # `Sync::Storage::ChunkStore` CALL, WHICH IS WHAT USED TO SIT HERE. Until Arc B Task 2 this
      # was CLAUDE.md §14c's one sanctioned chunk-internals reference (architecture_invariants_test.rb
      # pinned the maker layer's count at exactly one and named this file); it is gone, and that
      # test now pins the count at ZERO. The direct call was a `NameError` waiting to happen on any
      # deployment that does not load the sync engine in-process — `LIBRARY_BACKEND=chunk_remote` is
      # exactly that deployment, and every addon save there raised, measured against a live
      # standalone server.
      #
      # `#put_chunk` IS ITS OWN PORT VERB RATHER THAN A PARAMETER ON `#begin_upload`, for the same
      # three reasons that argument has always had (unchanged by this task — only the WRITE moved,
      # from a direct store call to a port call):
      #
      #   1. `#begin_upload` is genuinely a TWO-CALLER method with one shape: it hands back
      #      presigned PUT urls and never itself touches a byte, which is exactly what keeps
      #      CLAUDE.md 15 (bytes never flow through Rails) true for the flow it exists to serve —
      #      a BROWSER upload. Teaching it to also accept and write bytes on this caller's behalf
      #      would give the SAME METHOD two incompatible contracts ("I hand back URLs" vs. "I write
      #      bytes myself"), decided by which caller is asking — the kind of caller-shaped branch
      #      this class's other verbs (mkdir/move/delete/undelete) never need.
      #   2. A caller that already holds the bytes (this one) writes them itself, through the port;
      #      a caller that does not (the browser) PUTs them itself, straight to storage. Two
      #      different callers doing two different things was always the shape — `#put_chunk`
      #      exists so THIS caller's half is a port verb too, not a backdoor around one.
      #   3. It keeps `#begin_upload`'s contract identical for both callers: `result.missing` names
      #      exactly the chunks NOT YET in storage, exactly as it did before this task.
      #
      # AND `#put_chunk` CANNOT BE ONE SHARED HELPER EITHER — THE TWO ADAPTERS CANNOT SHARE ONE
      # IMPLEMENTATION, which is the whole reason this had to become a port verb rather than a
      # method on this class that both `Chunk` and `ChunkRemote` could call. On embedded chunk, a
      # presigned URL for the memory/local store can point BACK AT THIS SAME RAILS PROCESS (there
      # is no off-box store to presign to locally), so a server-side PUT to it would be a LOOPBACK
      # call into the same Puma pool — CLAUDE.md §14e's recorded reentrancy bug, measured at 14-24
      # second stalls and outright 404s. `FileLayer::Chunk#put_chunk` writes its store IN-PROCESS
      # instead; `FileLayer::ChunkRemote#put_chunk` PUTs to `begun.put_urls[hash]` over HTTP,
      # because on chunk_remote the URL always points at the STANDALONE sync server, never at this
      # app. Only the adapter knows which situation it is in — this caller does not, and must not
      # have to.
      def write_chunk(user, parent_node_id, f, replace = false)
        bytes = f[:bytes].b
        existing = (existing_at(user, parent_node_id, f[:name]) if replace)
        hash = Digest::SHA256.hexdigest(bytes)
        manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
        begun = FileLayer.current.begin_upload(
          user, device: addon_device(user), name: f[:name], parent_node_id:,
          node_id: existing&.node_id, base_version_id: existing&.current_version_id,
          size: bytes.bytesize, mtime: (Time.current.to_f * 1e9).to_i, manifest:
        )
        begun.missing.each { |h| FileLayer.current.put_chunk(user, begun:, hash: h, bytes:) }
        # verify: false, UNCHANGED FROM BEFORE THIS TASK — the bytes above were just written
        # SYNCHRONOUSLY, in this same method call (in-process on chunk, over one blocking HTTP PUT
        # on chunk_remote); re-verifying they landed would be a wasted storage round-trip
        # confirming something nothing between the two calls could have altered. See
        # FileLayer::Chunk#finalize_upload's own comment for the fuller argument (it is the same
        # one FilesController's `verify: true` is NOT this caller's case).
        # broadcast: false PRESERVES WHAT ADDON SAVES HAVE ALWAYS DONE -- they have never nudged
        # live devices, relying on the periodic sync instead. It is an explicit opt-out rather
        # than the port's default so that a THIRD caller of finalize_upload is safe by default;
        # see FileLayer::Chunk#finalize_upload's own comment. Not a decision this refactor makes
        # -- just the pre-existing one, now stated out loud at the one door that wants it.
        FileLayer.current.finalize_upload(user, commit_id: begun.commit_id, verify: false,
                                          broadcast: false)
        begun.node_id
      end

      # A dedicated device so addon writes are attributable and don't reuse a UI/session device.
      def addon_device(user)
        user.devices.find_by(name: "addons") || Device.register!(user:, name: "addons")
      end

      def enqueue_preview(user, node_id, name)
        info = FileLayer.current.stat(user, node_id:)
        return unless info&.content_token

        Maker::Previews::Enqueue.call(user:, node_id:, name:, version_id: info.content_token)
      rescue FileLayer::NotFound, FileLayer::FetchError
        nil
      end
    end
  end
end
