require "open3"
require "tempfile"

module Maker
  module Previews
    # STL → thumbnail PNG via the in-repo `stl-thumbnailer` binary (tools/stl-thumbnailer):
    # a pure-CPU software rasterizer (euc, Apache/MIT) — NO GPU, NO OpenGL/Mesa, NO headless
    # browser. The same crate also runs in the Tauri desktop core, so a device that holds the
    # file can render + upload the thumbnail; this server-side path is the universal fallback
    # (e.g. web uploads). Replaces F3D for `.stl` (F3D still covers obj/step via its OCCT plugin).
    #
    # `available?` gates on the binary being on PATH (overridable via STL_THUMBNAILER_BIN), so a
    # box without it fails the preview gracefully (the job marks `unsupported`) and tests SKIP.
    module Stl
      module_function

      RenderError = Class.new(StandardError)

      EXTENSIONS = %w[stl].freeze

      BIN = ENV.fetch("STL_THUMBNAILER_BIN", "stl-thumbnailer").freeze

      # WHICH BUILD OF THE RENDERER PRODUCED A STORED THUMBNAIL (§14h). A file's CONTENT is the only
      # staleness axis `Enqueue` checked before `renderer_revision` existed — and a finished design's
      # content never changes, so without this every STL already in a library keeps serving the
      # picture the old code made, forever.
      #
      #   1 -> the original Y-up camera, which rendered every Z-up print file lying on its side.
      #   2 -> Z-up (tools/stl-thumbnailer's `auto_frame`). Bumped BECAUSE the picture changed;
      #        that is the entire trigger, and it is why this constant exists rather than being
      #        inferred from anything.
      #   3 -> ink on paper (2026-10-21): a white ground and the palette's material
      #        (`Maker::Previews::Palette`), was a dark #202228 square with a cool grey material.
      #        `ThreeMf::THUMBNAIL_REVISION` moved with it — its mesh fallback renders through here.
      #
      # DECLARED HERE RATHER THAN ONLY IN THE RUST CRATE, because it is the RAILS side that has to
      # invalidate a cached artifact — the crate has no idea a `maker_previews` row exists. Rebuilding
      # the binary without bumping this leaves the library exactly as sideways as it was.
      THUMBNAIL_REVISION = 3

      # This renderer produces no `geometry` payload, so there is one number and `kind` cannot
      # change it. The signature still matches the measurable renderers' so `Enqueue.revision_for`
      # has one way to ask.
      def payload_revision(_kind) = THUMBNAIL_REVISION

      def available?
        # Running the binary (even with no/invalid args → usage + non-zero exit) confirms it
        # exists; only a missing/inexecutable binary raises ENOENT/EACCES.
        Open3.capture2e(BIN)
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # PNG thumbnail. `kind` is ignored (this renderer only produces thumbnails; the interactive
      # 3D/GLB path is client-side Three.js, not this). Returns { bytes:, content_type:, width:, height: }.
      def render(stl_bytes, size: 512, kind: "thumbnail", ext: nil) # rubocop:disable Lint/UnusedMethodArgument
        Tempfile.create([ "stl-in", ".stl" ]) do |fin|
          fin.binmode
          fin.write(stl_bytes.b)
          fin.flush

          out_path = "#{fin.path}.png"
          begin
            _stdout, stderr, status = Open3.capture3(BIN, fin.path, out_path, size.to_s, size.to_s)
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RenderError, "stl-thumbnailer failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end

            { bytes: File.binread(out_path), content_type: "image/png", width: size, height: size }
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT => e
        raise RenderError, "stl-thumbnailer not runnable: #{e.message}"
      end
    end
  end
end
