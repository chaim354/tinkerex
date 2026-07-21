require "open3"
require "tempfile"

module Maker
  module Previews
    # Raster image (png/jpg/gif/webp/bmp) → a downscaled PNG grid thumbnail via the `vipsthumbnail`
    # binary (libvips-tools). These already preview verbatim in the DETAIL view (SAFE_INLINE_TYPES
    # inlines them); the GRID wants one uniform, size-bounded raster instead of shipping full-res
    # photos into the cards.
    #
    # Deliberately a SUBPROCESS, not the ruby-vips FFI binding: in-process libvips spins up a thread
    # pool, and Rails' parallel test runner fork()s workers → libvips-in-a-forked-process deadlocks
    # (VIPS_CONCURRENCY=1 doesn't fix it). Every other renderer here shells out to a binary for the
    # same isolation; this matches them and keeps the Ruby process fork-safe.
    #
    # `available?` gates on the binary (overridable via VIPSTHUMBNAIL_BIN); a box without it degrades
    # these to `unsupported`, the same graceful path Stl/Mesh take without their binaries.
    module ImageThumb
      module_function

      RenderError = Class.new(StandardError)

      EXTENSIONS = %w[png jpg jpeg gif webp bmp].freeze

      BIN = ENV.fetch("VIPSTHUMBNAIL_BIN", "vipsthumbnail").freeze

      def available?
        Open3.capture2e(BIN, "--vips-version")
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # A size×size-bounded PNG (aspect preserved). `ext` picks the input suffix so vipsthumbnail
      # loads the right decoder. Returns { bytes:, content_type:, width:, height: }.
      def render(bytes, size: 512, ext: "png")
        suffix = ext.to_s.match?(/\A[a-z0-9]{1,5}\z/) ? ".#{ext}" : ".img"
        Tempfile.create([ "img-in", suffix ]) do |fin|
          fin.binmode
          fin.write(bytes.b)
          fin.flush

          out_path = "#{fin.path}.thumb.png"
          begin
            _stdout, stderr, status = Open3.capture3(BIN, fin.path, "--size", "#{size}x#{size}", "-o", out_path)
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RenderError, "vipsthumbnail failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end

            { bytes: File.binread(out_path), content_type: "image/png", width: size, height: size }
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT => e
        raise RenderError, "vipsthumbnail not runnable: #{e.message}"
      end
    end
  end
end
