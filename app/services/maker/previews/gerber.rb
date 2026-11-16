require "open3"
require "tmpdir"

module Maker
  module Previews
    # A Gerber layer or an Excellon drill file -> SVG -> PNG thumbnail, rendered by TRACESPACE UNDER
    # NODE (tools/gerber-svg/render.mjs) and rasterised by the shared SvgRasterizer. The same pinned
    # bundle the browser's viewer runs, built twice by bin/build-tracespace — so the tile, the poster
    # and the viewer are one picture, and no Gerber parser exists in Ruby (§14b: a second traversal
    # drifts from the first, privately). Exec'd like resvg/pdfium/f3d; nothing links node into Rails.
    #
    # EVERY `pcb`-ROLE EXTENSION EXCEPT `.gbrjob`. A job file is JSON naming its siblings; its
    # picture would need bytes this renderer is never handed (a renderer gets ONE file's contents and
    # cannot reach a directory), so it has no thumbnail — files-preview.md says so in the same words.
    # DERIVED from the one vocabulary, never a second list (§14d); registry_test.rb pins the relation
    # to FilesController::GERBER_EXTS so the two cannot drift.
    #
    # NO HAIRLINE STYLESHEET: tracespace draws real trace widths (SvgRasterizer::STYLESHEET and
    # tools/gerber-svg/render.mjs's header both say why the default exists and why it is wrong here).
    #
    # `available?` gates on node AND the vendored bundle; a box without either degrades every Gerber
    # to `unsupported` — the graceful path Stl/Mesh/Pdf take without their binaries.
    module Gerber
      module_function

      RenderError = Class.new(StandardError)

      EXTENSIONS = (Maker::FileAttachment::ROLE_BY_EXT
                      .select { |_ext, role| role == "pcb" }.keys - %w[gbrjob]).freeze

      SCRIPT = Rails.root.join("tools/gerber-svg/render.mjs").freeze
      BUNDLE = Rails.root.join("tools/gerber-svg/tracespace.mjs").freeze

      def node_bin = ENV.fetch("NODE_BIN", "node")

      # BOTH HALVES, because either one alone is a lie on a real box. A dev machine has node and no
      # vendored bundle until bin/build-tracespace has run; the deploy image has the bundle and,
      # before 2026-09-07, no node. Reporting available on one of those renders nothing and marks
      # the row `failed` instead of `unsupported`, which is the state Enqueue re-tries forever.
      def available?
        return false unless BUNDLE.exist?

        _out, status = Open3.capture2e(node_bin, "--version")
        status.success?
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      THUMBNAIL_REVISION = 1

      def payload_revision(_kind) = THUMBNAIL_REVISION

      # `ext` names the file for tracespace (it identifies the layer from the name, never from the
      # bytes). A size x size PNG.
      def render(bytes, size: 512, ext: "gbr")
        svg = svg_for(bytes, ext:)
        { bytes: rasterize(svg, size:).b, content_type: "image/png", width: size, height: size }
      end

      # THE ONE DOOR FROM A TRACESPACE RENDER TO A PNG, shared with GerberZip, because every such
      # call needs the same two things. NO HAIRLINE STYLESHEET: tracespace draws real trace widths
      # (the header above). AND THE PIPELINE'S LIMIT: this SVG is built from the same decompressed,
      # user-supplied geometry node was bounded for, and it is not a file the job capped, so the
      # reason resvg needs no limit elsewhere does not hold here (Maker::Previews::Subprocess).
      def rasterize(svg, size:)
        Maker::Previews::SvgRasterizer.to_png(svg, size:, stylesheet: nil, timeout: timeout_seconds)
      end

      # The SVG step on its own, so a test can assert geometry without decoding a PNG.
      def svg_for(bytes, ext:)
        Dir.mktmpdir("gerber-thumb") do |dir|
          path = File.join(dir, "layer.#{ext.to_s.downcase.delete_prefix('.')}")
          File.binwrite(path, bytes.b)
          run_node("layer", path)
        end
      end

      # THE ONE DOOR ONTO THE SUBPROCESS, shared with GerberZip's `board` mode. THE TWO STREAMS ARE
      # CAPTURED SEPARATELY AND NEVER MERGED (no `capture2e` shape): stderr carries render.mjs's own
      # reasons ("no layer could be parsed") and must not be spliced into the SVG on stdout. The
      # capture itself is Maker::Previews::Subprocess, which adds the wall-clock limit and nothing
      # else, and says there why this pipeline runs under one.
      #
      # EXIT 4 IS `Unsupported`, NOT A FAILURE, and the split is the reason render.mjs has two codes
      # rather than one. A layer that plots NOTHING is an ordinary artefact — a board with no bottom
      # silkscreen exports an empty `.gbo` — and tracespace renders it at `viewBox="0 0 0 0"`, which
      # resvg refuses ("SVG has no valid size"). As a RenderError that is a `failed` row, an error
      # badge on a file nothing is wrong with, re-rendered on every enqueue pass forever; `failed`
      # is the state Enqueue treats as "retry me". `unsupported` is this codebase's designated
      # deliberate, non-error, never-retried terminal state, which is exactly what "there is no
      # picture of this file" means. Naming the job's class from a renderer is Mesh's precedent
      # (it refuses `model_glb` the same way) and carries that method's argument.
      NOTHING_TO_DRAW = 4

      def run_node(mode, *paths)
        out, err, status = Subprocess.capture(node_bin, SCRIPT.to_s, mode, *paths,
                                              timeout: timeout_seconds, error: RenderError, name: "tracespace")
        if status.exitstatus == NOTHING_TO_DRAW
          raise ::Maker::GeneratePreviewJob::Unsupported, "this Gerber plots no geometry"
        end
        raise RenderError, "tracespace failed (#{status.exitstatus}): #{err.to_s[0, 300]}" unless status.success?
        raise RenderError, "tracespace produced no SVG" unless out.include?("<svg")

        out
      rescue Errno::ENOENT, Errno::EACCES => e
        raise RenderError, "node not runnable: #{e.message}"
      end

      # THE LIMIT EACH STEP OF A GERBER RENDER RUNS UNDER: node, and then resvg on node's output
      # (`rasterize` above). Each step gets the whole of it, so a render can take twice this.
      #
      # READ AT CALL TIME, like `node_bin` above and for the same reason: a constant frozen at boot
      # cannot be turned down for one deployment (or one test) without a redeploy. The default is
      # generous — a large multi-layer board renders in a second or two on the deploy box — because
      # this is a runaway guard, not a performance budget: too tight and it turns slow-but-fine
      # boards into `failed` rows the enqueue pass retries forever.
      #
      # A NON-POSITIVE VALUE FALLS BACK TO THE DEFAULT rather than being honoured. `to_i` answers 0
      # for a typo ("60s", "sixty"), and a 0 s bound is not "no limit" — `join(0)` returns
      # immediately, so EVERY Gerber render would time out, on a deployment whose only mistake was a
      # malformed env var.
      TIMEOUT_SECONDS = 60

      def timeout_seconds
        configured = ENV.fetch("GERBER_RENDER_TIMEOUT", TIMEOUT_SECONDS).to_i
        configured.positive? ? configured : TIMEOUT_SECONDS
      end
    end
  end
end
