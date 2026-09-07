require "test_helper"
require "support/gerber_fixture"
require "tmpdir"

module Maker
  module Previews
    # THE GERBER THUMBNAIL — tracespace under node (tools/gerber-svg/render.mjs), rasterised by the
    # shared SvgRasterizer.
    #
    # THE SVG STEP IS ASSERTED SEPARATELY FROM THE PNG, on purpose: `svg_for` is where the geometry
    # is, and a PNG assertion can only say "some bytes came back". A stroke-shaped claim is written
    # against a `.gtl` and NEVER a `.drl` — measured against this bundle, a drill hit is a filled
    # `<circle>` with no stroke at all, so "any Gerber renders a path" would be red on a working
    # renderer (the same trap test/system/gerber_test.rb's own header records).
    #
    # EVERY RENDER CASE SKIPS WHEN THE TOOLCHAIN IS ABSENT, the f3d precedent — and the skip names
    # which half is missing, because `available?` gates on node AND the vendored bundle and a box
    # can be missing either.
    class GerberTest < ActiveSupport::TestCase
      include GerberFixture

      # AN EMPTY LAYER: a real format/units header, no aperture, no D01 — so tracespace PARSES it
      # and plots nothing. This is an ordinary artefact (a board with no bottom silkscreen exports
      # an empty `.gbo`), and it is the case the plan expected `run_node` to refuse. Measured
      # instead: tracespace renders it happily at `viewBox="0 0 0 0" width="0mm" height="0mm"` and
      # RESVG is what refuses. See the `unsupported` case below for what that is worth.
      EMPTY_LAYER = "%FSLAX24Y24*%\n%MOMM*%\nM02*\n".freeze

      # A 2 mm-wide trace on a 10 mm board. Its whole purpose is the stylesheet case below: at
      # 2 mm this stroke is FOUR TIMES the fixture's 0.5 mm one, and the hairline stylesheet would
      # paint both at 1.5 device pixels.
      WIDE_TRACE = <<~GERBER.freeze
        %FSLAX24Y24*%
        %MOMM*%
        %ADD10C,2.0*%
        D10*
        X0Y0D02*
        X100000Y0D01*
        M02*
      GERBER

      def skip_without_node
        skip "node not available (Maker::Previews::Gerber.available? is false — needs node on " \
             "PATH/NODE_BIN and tools/gerber-svg/tracespace.mjs from bin/build-tracespace)" unless
          Maker::Previews::Gerber.available?
      end

      def skip_without_resvg
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?
      end

      test "available? is a boolean and gates on the vendored bundle as well as node" do
        assert_includes [ true, false ], Maker::Previews::Gerber.available?
        assert Maker::Previews::Gerber::BUNDLE.exist?,
               "tools/gerber-svg/tracespace.mjs is committed; run bin/build-tracespace"
        assert Maker::Previews::Gerber::SCRIPT.exist?
      end

      test "a layer renders an SVG holding a path" do
        skip_without_node

        svg = Maker::Previews::Gerber.svg_for(MINIMAL_GERBER, ext: "gtl")
        assert_includes svg, "<svg"
        assert_includes svg, "<path"
      end

      # THE DRILL FILE IS A `<circle>`, NOT A `<path>` — measured, and asserted here so the
      # difference is a recorded fact rather than something a later sweep "unifies" away.
      test "an Excellon drill file renders an SVG holding a circle" do
        skip_without_node

        svg = Maker::Previews::Gerber.svg_for(MINIMAL_DRILL, ext: "drl")
        assert_includes svg, "<svg"
        assert_includes svg, "<circle"
      end

      test "render returns a 512px PNG" do
        skip_without_node
        skip_without_resvg

        result = Maker::Previews::Gerber.render(MINIMAL_GERBER, ext: "gtl")
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b, "expected a PNG signature"
        assert_equal 512, result[:width]
        assert_equal 512, result[:height]
      end

      # DIFFERENT GEOMETRY MUST PRODUCE DIFFERENT BYTES, or every assertion above is satisfied by a
      # renderer that ignores its input.
      test "a square and a single trace do not render the same picture" do
        skip_without_node
        skip_without_resvg

        square = Maker::Previews::Gerber.render(MINIMAL_GERBER, size: 128, ext: "gtl")[:bytes]
        trace  = Maker::Previews::Gerber.render(WIDE_TRACE, size: 128, ext: "gtl")[:bytes]
        assert_not_equal square, trace, "the renderer is not reading its input"
      end

      # A LAYER THAT PLOTS NOTHING IS `unsupported`, NOT `failed`, AND THE DIFFERENCE IS NOT
      # COSMETIC: `failed` is the state Enqueue treats as "retry me", so an empty `.gbo` — which a
      # board with no bottom silkscreen exports as a matter of course — would carry an error badge
      # and be re-rendered on every enqueue pass forever. render.mjs answers exit 4 for it and
      # `run_node` maps that one code; every other non-zero exit stays a RenderError.
      test "a layer that plots nothing terminates unsupported rather than failing" do
        skip_without_node

        error = assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::Gerber.svg_for(EMPTY_LAYER, ext: "gbo")
        end
        assert_match(/plots no geometry/, error.message)
      end

      # THE STYLESHEET CASE, AND IT IS PINNED HERE RATHER THAN IN svg_rasterizer_test.rb BECAUSE
      # ONLY HERE CAN IT SEE THE CALLER. The rasterizer's own test proves the kwarg is honoured;
      # flipping `stylesheet: nil` back to the default in THIS file's `render` leaves that test
      # perfectly green. What this asserts is that `Gerber.render` produces the flagless picture:
      # a 2 mm trace rasterised through the hairline stylesheet is a 1.5 px line, which is a
      # visibly different image, so the two byte strings must differ.
      test "render does not apply the hairline stylesheet" do
        skip_without_node
        skip_without_resvg

        svg = Maker::Previews::Gerber.svg_for(WIDE_TRACE, ext: "gtl")
        hairlined = Maker::Previews::SvgRasterizer.to_png(
          svg, size: 128, stylesheet: Maker::Previews::SvgRasterizer::STYLESHEET
        )

        assert_not_equal hairlined,
                         Maker::Previews::Gerber.render(WIDE_TRACE, size: 128, ext: "gtl")[:bytes],
                         "Gerber.render is applying the hairline stylesheet — a 2 mm power trace " \
                         "and a 0.5 mm signal trace are then the same 1.5px line"
      end

      test "a node that cannot be run makes available? false and render raise RenderError" do
        original = ENV["NODE_BIN"]
        ENV["NODE_BIN"] = "/nonexistent/node-binary"

        assert_not Maker::Previews::Gerber.available?
        assert_raises(Maker::Previews::Gerber::RenderError) do
          Maker::Previews::Gerber.svg_for(MINIMAL_GERBER, ext: "gtl")
        end
      ensure
        if original.nil? then ENV.delete("NODE_BIN") else ENV["NODE_BIN"] = original end
      end

      # THE WALL-CLOCK BOUND, AND IT IS THE ELAPSED-TIME ASSERTION THAT CARRIES IT. "Raises
      # RenderError" alone is satisfied by a `wait_thr.join` with no timeout at all — that raises
      # too, twenty seconds later — which is exactly the mutation this case has to catch, so the
      # clock is read around the call. The script sleeps 20 s against a 1 s bound: long enough that
      # an unbounded join blows the 5 s assertion by four times over, short enough that the mutation
      # check costs twenty seconds rather than five minutes.
      #
      # A SHELL SCRIPT RATHER THAN REAL NODE, through NODE_BIN — the same door the "cannot be run"
      # case above uses, and it also means this case runs on a box with no node at all. The sleep is
      # NOT `exec`ed, deliberately: sh may leave `sleep` as a CHILD, which is the grandchild case
      # `capture_bounded` kills the process GROUP for. If only the direct child were killed the
      # orphan would keep the stdout pipe open and the reader thread would block for the full 20 s
      # — the timeout would fire and then hang anyway.
      test "a node that never exits is killed and raises RenderError" do
        original_bin = ENV["NODE_BIN"]
        original_timeout = ENV["GERBER_RENDER_TIMEOUT"]

        Dir.mktmpdir do |dir|
          script = File.join(dir, "slow-node")
          File.write(script, "#!/bin/sh\nsleep 20\n")
          File.chmod(0o755, script)
          ENV["NODE_BIN"] = script
          ENV["GERBER_RENDER_TIMEOUT"] = "1"

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          error = assert_raises(Maker::Previews::Gerber::RenderError) do
            Maker::Previews::Gerber.svg_for(MINIMAL_GERBER, ext: "gtl")
          end
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          # THE CLOCK IS ASSERTED FIRST, deliberately: `wait_thr.join(timeout)` reduced to
          # `wait_thr.join` still raises a RenderError twenty seconds later ("tracespace produced
          # no SVG"), so a message assertion placed ahead of this one would report the wrong
          # failure and hide the fact that nothing was bounded.
          assert_operator elapsed, :<, 5,
                          "the render took #{elapsed.round(1)}s against a 1s bound — the wait is " \
                          "not bounded, it just eventually returned"
          assert_match(/timed out/, error.message)
          assert_match(/1s/, error.message, "the message names the bound it waited for")
        end
      ensure
        if original_bin.nil? then ENV.delete("NODE_BIN") else ENV["NODE_BIN"] = original_bin end
        if original_timeout.nil?
          ENV.delete("GERBER_RENDER_TIMEOUT")
        else
          ENV["GERBER_RENDER_TIMEOUT"] = original_timeout
        end
      end

      # A MALFORMED TIMEOUT IS THE DEFAULT, NOT ZERO. `to_i` answers 0 for "60s" or "sixty", and a
      # 0 s bound is not "unbounded" — `join(0)` returns at once, so every Gerber on that deployment
      # would time out over one typo in an env var.
      test "a non-numeric render timeout falls back to the default rather than to zero" do
        original = ENV["GERBER_RENDER_TIMEOUT"]
        ENV["GERBER_RENDER_TIMEOUT"] = "sixty"
        assert_equal Maker::Previews::Gerber::TIMEOUT_SECONDS, Maker::Previews::Gerber.timeout_seconds
        ENV["GERBER_RENDER_TIMEOUT"] = "5"
        assert_equal 5, Maker::Previews::Gerber.timeout_seconds
      ensure
        if original.nil?
          ENV.delete("GERBER_RENDER_TIMEOUT")
        else
          ENV["GERBER_RENDER_TIMEOUT"] = original
        end
      end

      # BYTES THE PARSER CANNOT MAKE A LAYER OF terminate as a RenderError, not as an empty SVG
      # marked ready. render.mjs exits 3 with "no layer could be parsed" on an empty render.
      test "bytes that are not a Gerber raise RenderError" do
        skip_without_node

        assert_raises(Maker::Previews::Gerber::RenderError) do
          Maker::Previews::Gerber.svg_for("\x00\x01\x02 not a gerber at all", ext: "gtl")
        end
      end
    end
  end
end
