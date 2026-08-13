require "digest"
require "stringio"

module Maker
  module Addons
    # THE ONE generic write path for addon output. An addon hands over a SET of files of ANY type;
    # each is written into the file library through the existing FileLayer machinery and tied to
    # `state` as an AddonFile with its role. The helper never inspects the bytes. Backend-neutral:
    #   - share/s3 (port_writable): FileLayer#write (bytes -> file/object).
    #   - chunk (syncable):        a single-chunk Sync::Commit + Storage::ChunkStore#put, exactly
    #                              what the web uploader does, driven server-side (the bytes are
    #                              generated here — there is no client to presign for; §15 is aimed
    #                              at client uploads, and there is no client).
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
        caps = FileLayer.current.capabilities
        files.each_with_index.map do |f, i|
          dest = f.fetch(:parent_node_id, parent_node_id)
          replace = f[:replace].present?
          node_id = caps.port_writable? ? write_port(user, dest, f, replace) : write_chunk(user, dest, f, replace)
          enqueue_preview(user, node_id, f[:name])
          upsert_file!(state, node_id:, role: f[:role], content_type: f[:content_type], position: i)
        end
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
      def existing_at(user, parent_node_id, name)
        user.nodes.present.find_by(parent_node_id:, name:, kind: "file")
      end

      # --- share / s3 -----------------------------------------------------------
      def write_port(user, parent_node_id, f, replace = false)
        info = FileLayer.current.write(user, parent_node_id:, name: f[:name],
                                       io: StringIO.new(f[:bytes].b), replace:)
        info.node_id
      end

      # --- chunk: single-chunk two-phase commit, driven server-side -------------
      #
      # A REPLACE HERE IS JUST A NEW VERSION, which is what versioning is FOR — commit against the
      # existing node_id with its current version as `base_version_id`, and the sync engine treats
      # it as the ordinary fast-forward it is (§6: a base that IS current is a clean fast-forward;
      # a stale one becomes a recorded conflict rather than a silent drop). So chunk needs no port
      # involvement at all, and unlike share/s3 the old bytes stay restorable.
      def write_chunk(user, parent_node_id, f, replace = false)
        bytes = f[:bytes].b
        existing = (existing_at(user, parent_node_id, f[:name]) if replace)
        node_id = existing&.node_id || SecureRandom.uuid
        commit_id = SecureRandom.uuid
        hash = Digest::SHA256.hexdigest(bytes)
        manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
        result = Sync::Commit.begin(
          user:, device: addon_device(user), commit_id:, node_id:, parent_node_id:,
          name: f[:name], base_version_id: existing&.current_version_id, size: bytes.bytesize,
          mtime: (Time.current.to_f * 1e9).to_i, manifest:
        )
        result.missing.each { |h| Storage::ChunkStore.current.put(user.id, h, bytes) }
        Sync::Commit.finalize(user:, commit_id:, verify: false)
        node_id
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
