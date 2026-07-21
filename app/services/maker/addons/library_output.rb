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
    # v1 writes FLAT to `parent_node_id` (default: root) with the caller's names, and CREATES (no
    # clobber/versioning) — see the plan's scope note; the AddonFile join is the tie.
    module LibraryOutput
      module_function

      # files: [{ name:, bytes:, content_type:, role: }]. Returns the created AddonFiles.
      def write(user:, state:, parent_node_id:, files:)
        caps = FileLayer.current.capabilities
        files.each_with_index.map do |f, i|
          node_id = caps.port_writable? ? write_port(user, parent_node_id, f) : write_chunk(user, parent_node_id, f)
          enqueue_preview(user, node_id, f[:name])
          state.files.create!(node_id:, role: f[:role], content_type: f[:content_type], position: i)
        end
      end

      # --- share / s3 -----------------------------------------------------------
      def write_port(user, parent_node_id, f)
        info = FileLayer.current.write(user, parent_node_id:, name: f[:name], io: StringIO.new(f[:bytes].b))
        info.node_id
      end

      # --- chunk: single-chunk two-phase commit, driven server-side -------------
      def write_chunk(user, parent_node_id, f)
        bytes = f[:bytes].b
        node_id = SecureRandom.uuid
        commit_id = SecureRandom.uuid
        hash = Digest::SHA256.hexdigest(bytes)
        manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
        result = Sync::Commit.begin(
          user:, device: addon_device(user), commit_id:, node_id:, parent_node_id:,
          name: f[:name], base_version_id: nil, size: bytes.bytesize,
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
