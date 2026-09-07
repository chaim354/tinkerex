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
        png = Maker::Previews::SvgRasterizer.to_png(svg, size:, stylesheet: nil)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
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
      # capture itself is `capture_bounded` below, which adds the wall-clock bound and nothing else.
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
        out, err, status = capture_bounded(node_bin, SCRIPT.to_s, mode, *paths)
        if status.exitstatus == NOTHING_TO_DRAW
          raise ::Maker::GeneratePreviewJob::Unsupported, "this Gerber plots no geometry"
        end
        raise RenderError, "tracespace failed (#{status.exitstatus}): #{err.to_s[0, 300]}" unless status.success?
        raise RenderError, "tracespace produced no SVG" unless out.include?("<svg")

        out
      rescue Errno::ENOENT, Errno::EACCES => e
        raise RenderError, "node not runnable: #{e.message}"
      end

      # THE ONLY RENDERER HERE WITH A WALL-CLOCK BOUND, AND THE ASYMMETRY IS DELIBERATE — do not
      # "unify" it away by dropping it, and do not copy it around either. resvg, pdfium, f3d and
      # stl-thumbnailer are each handed ONE file whose size the job has already capped at
      # MAX_PREVIEW_BYTES. This one is handed a DECOMPRESSED, USER-SUPPLIED GEOMETRY BUDGET: a zip
      # is bounded at 32 MB compressed and up to MAX_EXTRACTED_BYTES (64 MB) of layers inflate out
      # of it, and tracespace's cost is in the plotted geometry rather than the byte count. Measured
      # in review: one hand-built archive held a Solid Queue worker for 104 s before the OOM killer
      # ended node. Without this, a node that hangs — or merely grinds — wedges that worker
      # INDEFINITELY, and a worker is a shared resource, so the whole preview queue stalls behind
      # one bad file. A kill is the honest answer: the render is retried as `failed`, not lost.
      #
      # `Open3.popen3` and not `capture3`, and STDOUT/STDERR ARE DRAINED IN THEIR OWN THREADS.
      # A board's SVG is several MB, far past a pipe buffer, so a single-threaded "wait then read"
      # deadlocks: the child blocks writing stdout while we block on `join`, and the timeout then
      # fires on a render that was working. `join(timeout)` answers nil exactly when the child is
      # still running, which is the signal — never an elapsed-time comparison of our own.
      #
      # KILL, NOT TERM, AND THE WHOLE PROCESS GROUP (`pgroup: true`, then a signal to `-pid`). Two
      # reasons, and the second is the one that is easy to miss: this subprocess has no cleanup
      # worth running and a wedged node may ignore TERM entirely; and a GRANDCHILD INHERITS THE
      # STDOUT PIPE, so killing the direct child alone leaves the write end open and the reader
      # thread below blocks until that orphan exits — the timeout would then hand back exactly the
      # hang it exists to end. `Errno::ESRCH` is the benign race where the group was already gone
      # between the join and the signal. The reap (`wait_thr.join`) and the two reader joins run
      # before the raise so nothing is left behind: no zombie, no thread reading a dead pipe.
      def capture_bounded(*cmd)
        timeout = timeout_seconds
        Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          out_thread = Thread.new { stdout.read }
          err_thread = Thread.new { stderr.read }
          unless wait_thr.join(timeout)
            begin
              Process.kill("KILL", -wait_thr.pid)
            rescue Errno::ESRCH
              nil
            end
            wait_thr.join
            out_thread.join
            err_thread.join
            raise RenderError, "tracespace timed out after #{timeout}s"
          end
          [ out_thread.value, err_thread.value, wait_thr.value ]
        end
      end

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
