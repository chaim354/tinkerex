# Server-side Thumbnail Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every renderable 2D/3D file a static PNG thumbnail, generated eagerly when its bytes land, shown in the web file grid and single-file view, behind an easily-extended renderer seam.

**Architecture:** Build on the existing `Maker::Previews` engine (Registry → renderer → `GeneratePreviewJob` → `Maker::Preview` + ActiveStorage asset served off Rails). Normalize the 2D vector renderers (SVG/DXF/LightBurn) to PNG via a new `SvgRasterizer` (resvg subprocess). Add a shared renderer contract test as the extensibility guarantee, an idempotent `Previews::Enqueue` helper called from the "bytes landed" seams, and the web UI surfaces that display the thumbnails.

**Tech Stack:** Rails 8, Minitest, ActiveStorage, Solid Queue, Stimulus; `resvg` CLI (Rust, MPL-2.0/Apache — permissive per §9); existing `stl-thumbnailer` binary; rubyzip.

**Spec:** `docs/superpowers/specs/2026-07-20-server-side-thumbnail-previews-design.md`

**Backends:** the suite runs three legs — `bin/rails test` (chunk), `LIBRARY_BACKEND=share bin/rails test`, `LIBRARY_BACKEND=s3 bin/rails test`. Preview *rendering* is backend-neutral (bytes come through `Maker::FileBytes` → `FileLayer`); the eager *enqueue seams* differ per backend, so Task 6 tests all three.

**Toolchain note:** the dev/CI boxes may not have `resvg`. Renderers gate on it via `available?`, so a box without it degrades SVG/DXF/LightBurn to `unsupported` (a non-error terminal state, exactly like `Stl`/`Mesh` without their binaries). Tests are written to pass **with or without** resvg (branch on `available?`), and Task 9 installs it in the deploy image + CI so the real PNG path is exercised there.

---

## Task 0: Install resvg locally (prep, no commit)

**Purpose:** so you can watch the PNG path go green locally. Not committed.

- [ ] **Step 1: Install resvg**

Run: `brew install resvg`
Expected: installs resvg 0.47.x. Verify: `resvg --version` prints a version.

- [ ] **Step 2: Confirm the CLI flags this plan assumes**

Run: `resvg --help`
Expected: usage shows a positional `<in-svg> <out-png>` and size flags `--width`/`--height` (0.47 uses these). If your resvg spells them differently (e.g. `-w`/`-h`), note it — `SvgRasterizer::ARGS` in Task 1 is the single place to adjust.

---

## Task 1: `SvgRasterizer` — the one SVG→PNG step

**Files:**
- Create: `app/services/maker/previews/svg_rasterizer.rb`
- Test: `test/services/maker/previews/svg_rasterizer_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/previews/svg_rasterizer_test.rb
require "test_helper"

module Maker
  module Previews
    class SvgRasterizerTest < ActiveSupport::TestCase
      SQUARE = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10"><rect width="10" height="10" fill="#000"/></svg>).freeze

      test "available? reflects whether the resvg binary is runnable" do
        assert_includes [ true, false ], Maker::Previews::SvgRasterizer.available?
      end

      test "to_png returns real PNG bytes (magic header) at the requested size" do
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?

        png = Maker::Previews::SvgRasterizer.to_png(SQUARE, size: 64)
        assert_equal "\x89PNG\r\n\x1A\n".b, png[0, 8].b, "expected a PNG signature"
        assert_operator png.bytesize, :>, 0
      end

      test "malformed SVG raises RasterizeError, not an arbitrary exception" do
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?

        assert_raises(Maker::Previews::SvgRasterizer::RasterizeError) do
          Maker::Previews::SvgRasterizer.to_png("not an svg at all", size: 64)
        end
      end

      test "a missing binary makes available? false and to_png raise RasterizeError" do
        original = ENV["RESVG_BIN"]
        ENV["RESVG_BIN"] = "/nonexistent/resvg-binary"
        Maker::Previews::SvgRasterizer.reset_bin!
        assert_not Maker::Previews::SvgRasterizer.available?
        assert_raises(Maker::Previews::SvgRasterizer::RasterizeError) do
          Maker::Previews::SvgRasterizer.to_png("<svg/>", size: 64)
        end
      ensure
        ENV["RESVG_BIN"] = original
        Maker::Previews::SvgRasterizer.reset_bin!
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/previews/svg_rasterizer_test.rb`
Expected: FAIL — `uninitialized constant Maker::Previews::SvgRasterizer`.

- [ ] **Step 3: Write the implementation**

```ruby
# app/services/maker/previews/svg_rasterizer.rb
require "open3"
require "tempfile"

module Maker
  module Previews
    # SVG string -> PNG bytes, via the `resvg` CLI (Rust, MPL-2.0/Apache -- permissive, CLAUDE.md
    # §9). A single static binary, NO GPU / OpenGL / Mesa / headless browser -- the same posture as
    # `stl-thumbnailer`. This is the ONE rasterize step: Svg/Dxf/Lbrn2 all route their generated
    # SVG through here, so every 2D-vector thumbnail comes out as a uniform PNG (which is also why
    # the web layer can inline it -- an SVG could carry <script>, a PNG cannot).
    #
    # `available?` gates on the binary being runnable (overridable via RESVG_BIN), so a box without
    # resvg degrades the SVG/DXF/LightBurn renderers to `unsupported` rather than crashing -- the
    # same graceful path Stl/Mesh take when their toolchain is absent.
    module SvgRasterizer
      module_function

      RasterizeError = Class.new(StandardError)

      # resvg positional in/out + square target size. If your resvg spells the size flags
      # differently (Task 0 step 2), this array is the only thing to change.
      def bin = @bin ||= ENV.fetch("RESVG_BIN", "resvg")

      def reset_bin! = @bin = nil

      def available?
        # Running with no args prints usage + a non-zero exit; only a missing/inexecutable binary
        # raises ENOENT/EACCES.
        Open3.capture2e(bin)
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # SVG bytes/string -> PNG bytes (a size×size raster; the SVG's preserveAspectRatio fits it).
      def to_png(svg, size: 512)
        Tempfile.create([ "resvg-in", ".svg" ]) do |fin|
          fin.binmode
          fin.write(svg.to_s.b)
          fin.flush

          out_path = "#{fin.path}.png"
          begin
            _stdout, stderr, status = Open3.capture3(
              bin, "--width", size.to_s, "--height", size.to_s, fin.path, out_path
            )
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RasterizeError, "resvg failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end
            File.binread(out_path)
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT, Errno::EACCES => e
        raise RasterizeError, "resvg not runnable: #{e.message}"
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/services/maker/previews/svg_rasterizer_test.rb`
Expected: PASS (the two render tests skip if resvg is absent; the missing-binary test always runs).

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/previews/svg_rasterizer.rb test/services/maker/previews/svg_rasterizer_test.rb
git commit -m "feat(previews): SvgRasterizer — SVG→PNG via resvg subprocess"
```

---

## Task 2: `Svg` renderer emits PNG (DXF/LightBurn inherit it)

**Files:**
- Modify: `app/services/maker/previews/svg.rb`
- Modify (tests): `test/services/maker/previews/svg_test.rb`

`Dxf`/`Lbrn2` already build an SVG with `to_svg` then delegate to `Svg.render`, and their `available?` already delegates to `Svg.available?` — so changing `Svg` alone flips all three to PNG. Their internal `to_svg` tests (asserting `<svg>`/`<line>`) stay valid.

- [ ] **Step 1: Rewrite the SVG renderer test for PNG output**

Replace the whole file:

```ruby
# test/services/maker/previews/svg_test.rb
require "test_helper"

module Maker
  module Previews
    class SvgTest < ActiveSupport::TestCase
      setup { @svg = File.binread(Rails.root.join("test/fixtures/files/square.svg")) }

      test "available? mirrors the resvg rasterizer" do
        assert_equal Maker::Previews::SvgRasterizer.available?, Maker::Previews::Svg.available?
      end

      test "renders the SVG to a PNG thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        result = Maker::Previews::Svg.render(@svg, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
        assert_equal 256, result[:width]
        assert_equal 256, result[:height]
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/previews/svg_test.rb`
Expected: FAIL — the render test gets `image/svg+xml`, not `image/png` (or fails on the old verbatim-bytes behavior).

- [ ] **Step 3: Rewrite `Svg.render`**

Replace the module body of `app/services/maker/previews/svg.rb`:

```ruby
module Maker
  module Previews
    # SVG (`.svg`) -> PNG thumbnail.
    #
    # An SVG is browser-renderable, but we deliberately DO NOT serve it verbatim: the web layer
    # treats user SVG as an XSS vector (SVG can carry <script>) and refuses to inline it, and the
    # grid wants one uniform raster type. So we rasterize to PNG via SvgRasterizer (resvg). Dxf and
    # Lbrn2 build an SVG and delegate here, so this is the single 2D-vector rasterize point.
    #
    # `available?` gates on the rasterizer -> a box without resvg degrades .svg/.dxf/.lbrn to
    # `unsupported` (a non-error terminal state), same as Stl/Mesh without their binaries.
    module Svg
      module_function

      EXTENSIONS = %w[svg].freeze

      def available? = Maker::Previews::SvgRasterizer.available?

      # Returns { bytes:, content_type:, width:, height: } — a size×size PNG.
      def render(svg_bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(svg_bytes, size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end
    end
  end
end
```

- [ ] **Step 4: Run the SVG/DXF/LightBurn renderer tests**

Run: `bin/rails test test/services/maker/previews/svg_test.rb test/services/maker/previews/dxf_test.rb test/services/maker/previews/lbrn2_test.rb`
Expected: `svg_test` PASS. `dxf_test`/`lbrn2_test` — the `to_svg` tests PASS; any `render` test still asserting `image/svg+xml` FAILS. Fix those in Step 5.

- [ ] **Step 5: Update DXF/LightBurn `render` assertions to PNG (conditional)**

In `test/services/maker/previews/dxf_test.rb` and `test/services/maker/previews/lbrn2_test.rb`, find the test(s) whose assertion is on `Dxf.render`/`Lbrn2.render` returning `image/svg+xml` with `<svg`/`<line`/`<svg` bytes. Replace each such `render`-level test with:

```ruby
      test "render produces a PNG thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Dxf.available?  # Lbrn2 in lbrn2_test.rb

        result = Maker::Previews::Dxf.render(@dxf, size: 256)   # @lbrn2 / Lbrn2 in lbrn2_test.rb
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
      end
```

Leave every `to_svg`-level test (asserting `<svg>`, `<line>`, colors, viewBox, etc.) unchanged — `to_svg` still produces SVG.

- [ ] **Step 6: Run them again**

Run: `bin/rails test test/services/maker/previews/svg_test.rb test/services/maker/previews/dxf_test.rb test/services/maker/previews/lbrn2_test.rb`
Expected: PASS (render tests skip if resvg absent; to_svg tests always pass).

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews/svg.rb test/services/maker/previews/svg_test.rb test/services/maker/previews/dxf_test.rb test/services/maker/previews/lbrn2_test.rb
git commit -m "feat(previews): normalize SVG/DXF/LightBurn thumbnails to PNG"
```

---

## Task 3: Decouple orchestrator tests from resvg; PNG-ify the job's SVG assertions

`GeneratePreviewJob` uses `.svg` fixtures for tests that are really about *orchestration* (name resolution) and for SVG-specific rendering. With SVG now gated on resvg, the orchestration tests must not depend on it — switch them to the always-available `3mf` fixture (embedded thumbnail → PNG, pure Ruby). The SVG/DXF/LightBurn *render* tests branch on `available?` like the existing `Stl` test.

**Files:**
- Modify: `test/jobs/maker/generate_preview_job_test.rb`

- [ ] **Step 1: Switch the two name-resolution tests to the 3MF fixture**

In `test/jobs/maker/generate_preview_job_test.rb`:

Test **"derives the extension from node_id when no filename is given"** — replace its body with a 3MF variant (always available):

```ruby
    test "derives the extension from node_id when no filename is given" do
      threemf = File.binread(Rails.root.join("test/fixtures/files/cube.3mf"))
      stage_version(node_id: "drawing.3mf", version_id: "v1", bytes: threemf)
      preview = @user.maker_previews.create!(node_id: "drawing.3mf", version_id: "v1")

      Maker::GeneratePreviewJob.perform_now(preview.id)

      assert_equal "ready", preview.reload.status
    end
```

Test **"no filename: resolves the renderable name from the Node row (extensionless node_id)"** — keep its structure but use the 3MF fixture + name, and assert PNG:

```ruby
    test "no filename: resolves the renderable name from the Node row (extensionless node_id)" do
      node_id = "11111111-2222-3333-4444-555555555555"
      threemf = File.binread(Rails.root.join("test/fixtures/files/cube.3mf"))
      stage_version(node_id:, version_id: "v1", bytes: threemf, name: "drawing.3mf")
      preview = @user.maker_previews.create!(node_id:, version_id: "v1", kind: "thumbnail")

      Maker::GeneratePreviewJob.perform_now(preview.id)

      preview.reload
      assert_equal "ready", preview.status
      assert preview.asset.attached?
      assert_equal "image/png", preview.asset.content_type
      assert_nil preview.error
    end
```

- [ ] **Step 2: Make the SVG/DXF/LightBurn render tests branch on availability**

Replace the test **"renders SVG, attaches the asset, flips status to ready"** with:

```ruby
    test "renders SVG to a PNG when resvg is present; unsupported when absent" do
      stage_version(node_id: "n1.svg", version_id: "v1", bytes: @svg)
      preview = @user.maker_previews.create!(node_id: "n1.svg", version_id: "v1", kind: "thumbnail")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "drawing.svg") }

      preview.reload
      if Maker::Previews::Svg.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
        assert_equal "\x89PNG".b, preview.asset.download[0, 4].b
      else
        assert_equal "unsupported", preview.status
        assert_not preview.asset.attached?
      end
    end
```

Replace **"renders a LightBurn .lbrn2 → ready SVG"** and **"renders a DXF → ready SVG"** with the same branch shape (PNG when available, unsupported when not):

```ruby
    test "renders a LightBurn .lbrn2 to PNG when resvg is present; unsupported when absent" do
      lbrn2 = File.binread(Rails.root.join("test/fixtures/files/sample.lbrn2"))
      stage_version(node_id: "art.lbrn2", version_id: "vlb", bytes: lbrn2)
      preview = @user.maker_previews.create!(node_id: "art.lbrn2", version_id: "vlb")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "art.lbrn2") }

      preview.reload
      if Maker::Previews::Lbrn2.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
      else
        assert_equal "unsupported", preview.status
      end
    end

    test "renders a DXF to PNG when resvg is present; unsupported when absent" do
      dxf = File.binread(Rails.root.join("test/fixtures/files/sample.dxf"))
      stage_version(node_id: "plate.dxf", version_id: "vdxf", bytes: dxf)
      preview = @user.maker_previews.create!(node_id: "plate.dxf", version_id: "vdxf")

      assert_nothing_raised { Maker::GeneratePreviewJob.perform_now(preview.id, filename: "plate.dxf") }

      preview.reload
      if Maker::Previews::Dxf.available?
        assert_equal "ready", preview.status
        assert_equal "image/png", preview.asset.content_type
      else
        assert_equal "unsupported", preview.status
      end
    end
```

Leave the 3MF, STL, unsupported, discard, transient-retry, and missing-chunk tests unchanged (they don't depend on resvg).

- [ ] **Step 3: Run the job tests**

Run: `bin/rails test test/jobs/maker/generate_preview_job_test.rb`
Expected: PASS on this box (resvg present after Task 0; the branches also pass if absent).

- [ ] **Step 4: Commit**

```bash
git add test/jobs/maker/generate_preview_job_test.rb
git commit -m "test(previews): decouple orchestrator tests from resvg; assert PNG output"
```

---

## Task 4: Shared renderer contract test (the extensibility guarantee)

Mirrors `test/services/file_layer/adapter_contract.rb`: one test that iterates **every** renderer registered in `Registry` and pins the interface, so a new format added to the registry is automatically checked and a renderer that lies about its output can't merge.

**Files:**
- Create: `test/services/maker/previews/renderer_contract_test.rb`

- [ ] **Step 1: Write the contract test**

```ruby
# test/services/maker/previews/renderer_contract_test.rb
require "test_helper"

module Maker
  module Previews
    # THE EXTENSIBILITY BACKSTOP. Every renderer in Registry::RENDERERS runs against this one
    # contract, so adding a format is: write a module (available?/render/EXTENSIONS), register one
    # line, drop a fixture into the map below -> covered. A renderer that returns the wrong shape,
    # a non-raster content_type (an SVG the web layer can't safely inline), or non-image bytes
    # cannot merge. Renderers whose toolchain is absent on this box are checked structurally and
    # skip the render assertion (same graceful path the engine takes at runtime).
    class RendererContractTest < ActiveSupport::TestCase
      # Renderer => a fixture file that renderer can actually render. A renderer with no fixture
      # here is still checked structurally; it just can't be exercised end-to-end.
      FIXTURES = {
        Maker::Previews::Svg     => "square.svg",
        Maker::Previews::Dxf     => "sample.dxf",
        Maker::Previews::Lbrn2   => "sample.lbrn2",
        Maker::Previews::ThreeMf => "cube.3mf",
        Maker::Previews::Stl     => "tetra.stl"
        # Mesh (obj/step/iges) intentionally omitted: F3D is not on this box, so it is checked
        # structurally only. Add a fixture here if/when F3D lands in the test env.
      }.freeze

      # Raster types the web grid can inline safely (FilesController::SAFE_INLINE_TYPES minus svg).
      RASTER_TYPES = %w[image/png image/jpeg image/gif image/webp image/bmp].freeze

      def renderers = Maker::Previews::Registry::RENDERERS.values.uniq

      test "every registered renderer exposes the interface" do
        renderers.each do |r|
          assert_respond_to r, :available?, "#{r} must answer available?"
          assert_respond_to r, :render,     "#{r} must answer render"
          assert r.const_defined?(:EXTENSIONS), "#{r} must define EXTENSIONS"
          assert_includes [ true, false ], r.available?, "#{r}#available? must be a Boolean"
        end
      end

      test "every EXTENSIONS entry is lowercase and resolves back to its renderer" do
        renderers.each do |r|
          r::EXTENSIONS.each do |ext|
            assert_equal ext, ext.downcase, "#{r} EXTENSIONS must be lowercase (#{ext})"
            assert_equal r, Maker::Previews::Registry.for(ext),
                         "#{r} claims .#{ext} but Registry.for(#{ext}) disagrees"
          end
        end
      end

      test "when available and given a valid fixture, render returns an inline-safe raster image" do
        FIXTURES.each do |renderer, fixture|
          next unless renderer.available?

          bytes = File.binread(Rails.root.join("test/fixtures/files", fixture))
          ext = File.extname(fixture).delete_prefix(".")
          result = render_with(renderer, bytes, ext)

          assert_kind_of Hash, result, "#{renderer}#render must return a Hash"
          assert_includes RASTER_TYPES, result[:content_type],
                          "#{renderer} thumbnail must be an inline-safe raster type, got #{result[:content_type]}"
          assert result[:bytes] && result[:bytes].bytesize.positive?,
                 "#{renderer} must return non-empty bytes"
        end
      end

      private

      # Renderers share render(bytes, size:); some also take ext:. Pass ext only when accepted.
      def render_with(renderer, bytes, ext)
        accepted = renderer.method(:render).parameters.select { |t, _| %i[key keyreq].include?(t) }.map(&:last)
        opts = { size: 128 }
        opts[:ext] = ext if accepted.include?(:ext)
        renderer.render(bytes, **opts)
      end
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `bin/rails test test/services/maker/previews/renderer_contract_test.rb`
Expected: PASS. (With resvg present, Svg/Dxf/Lbrn2 assert PNG; 3MF asserts its PNG; Stl asserts PNG if `stl-thumbnailer` is on PATH else skips its render leg; Mesh is structural-only.)

- [ ] **Step 3: Prove the contract bites (manual check, then revert)**

Temporarily edit `app/services/maker/previews/svg.rb` `render` to return `content_type: "image/svg+xml"`. Run the contract test — expect FAIL on "inline-safe raster type". Revert the edit; re-run — PASS. (Do not commit the temporary edit.)

- [ ] **Step 4: Commit**

```bash
git add test/services/maker/previews/renderer_contract_test.rb
git commit -m "test(previews): shared renderer contract across the registry"
```

---

## Task 5: `Previews::Enqueue` — one idempotent entry point

**Files:**
- Create: `app/services/maker/previews/enqueue.rb`
- Test: `test/services/maker/previews/enqueue_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/previews/enqueue_test.rb
require "test_helper"

module Maker
  module Previews
    class EnqueueTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup { @user = User.create!(email: "enq@example.com") }

      test "creates a pending thumbnail preview and enqueues the job" do
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
        p = @user.maker_previews.find_by(node_id: "n1", version_id: "v1", kind: "thumbnail")
        assert_equal "pending", p.status
      end

      test "is idempotent: re-enqueuing a ready (node, version) does not enqueue again" do
        p = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "ready")
        assert_no_enqueued_jobs do
          result = Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
          assert_equal p.id, result.id
        end
      end

      test "re-enqueues a previously failed preview" do
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "failed")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end

      test "a new version is a new preview row + a new job (supersede)" do
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "ready")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v2")
        end
        assert @user.maker_previews.exists?(node_id: "n1", version_id: "v2", kind: "thumbnail")
      end

      test "does nothing for a name with no registered renderer" do
        assert_no_enqueued_jobs do
          result = Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.sldprt", version_id: "v1")
          assert_nil result
        end
        assert_not @user.maker_previews.exists?(node_id: "n1")
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/previews/enqueue_test.rb`
Expected: FAIL — `uninitialized constant Maker::Previews::Enqueue`.

- [ ] **Step 3: Write the implementation**

```ruby
# app/services/maker/previews/enqueue.rb
module Maker
  module Previews
    # THE ONE idempotent entry point the "bytes landed" seams call (web upload, API commit, scan).
    # Finds-or-creates the (node, version, kind: thumbnail) Preview and enqueues GeneratePreviewJob
    # only when it is new or previously `failed`. A new version_id is a new row (the model's unique
    # index), so an edited file re-renders. Returns the Preview, or nil when nothing to do (no
    # renderer for this name -> don't litter the table with rows that will only ever be
    # `unsupported`; that judgement is cheap and local here, and keeps the grid's preview map clean).
    #
    # NOT a controller concern and NOT sync-coupled: it reads a filename + content id and enqueues a
    # job. Callable from a controller, a service, or a scan loop (§10 tripwire stays intact).
    module Enqueue
      module_function

      def call(user:, node_id:, name:, version_id:, kind: "thumbnail")
        return nil if Maker::Previews::Registry.for_filename(name).nil?

        preview = user.maker_previews.find_or_initialize_by(node_id:, version_id:, kind:)
        return preview unless preview.new_record? || preview.status == "failed"

        preview.status = "pending"
        preview.save!
        Maker::GeneratePreviewJob.perform_later(preview.id, filename: name)
        preview
      end
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/services/maker/previews/enqueue_test.rb`
Expected: PASS.

- [ ] **Step 5: DRY the v1 controller onto the helper**

Modify `app/controllers/v1/maker/previews_controller.rb#create` to reuse `Enqueue` for the enqueue decision (it currently inlines the same logic). Replace the body of `create` with:

```ruby
      def create
        attrs = preview_params
        name = attrs[:filename].presence ||
               current_user.nodes.find_by(node_id: attrs[:node_id])&.name ||
               attrs[:node_id]
        preview = ::Maker::Previews::Enqueue.call(
          user: current_user, node_id: attrs[:node_id],
          name:, version_id: attrs[:version_id], kind: attrs.fetch(:kind, "thumbnail")
        )
        # nil => no renderer for this name. Create the row anyway so the client can observe the
        # terminal `unsupported` state (the API's existing contract), without enqueuing a job.
        preview ||= current_user.maker_previews.create!(
          node_id: attrs[:node_id], version_id: attrs[:version_id],
          kind: attrs.fetch(:kind, "thumbnail"), status: "unsupported",
          error: "no preview renderer for #{name}"
        )
        render json: preview_json(preview), status: (preview.previous_changes.key?("id") ? :created : :ok)
      end
```

- [ ] **Step 6: Run the v1 previews integration tests**

Run: `bin/rails test test/integration/v1/maker/previews_test.rb test/integration/v1/maker/previews_reenqueue_test.rb`
Expected: PASS. If an assertion pinned the old `:created`/`:ok` distinction differently, reconcile it against the behavior above (new row → 201, existing → 200). Adjust the test only if the *observable* contract is unchanged.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews/enqueue.rb test/services/maker/previews/enqueue_test.rb app/controllers/v1/maker/previews_controller.rb
git commit -m "feat(previews): Previews::Enqueue idempotent helper; reuse in v1 API"
```

---

## Task 6: Wire eager enqueue into the "bytes landed" seams

Call `Previews::Enqueue` wherever a file's bytes newly land. `version_id` is uniform across backends: `FileLayer::FileInfo#content_token` is the value stored in `maker_previews.version_id` (see `app/services/file_layer/file_info.rb`).

**Files:**
- Modify: `app/controllers/files_controller.rb` (`create`, `finalize_upload`)
- Modify: `app/controllers/v1/commits_controller.rb` (`finalize`)
- Modify: `app/services/library/reconciler.rb` (`create_or_revive!`)
- Test: `test/controllers/files_preview_enqueue_test.rb` (new)
- Test: extend `test/integration/v1/commits...` (see Step 7) and a Reconciler test

- [ ] **Step 1: Add a private enqueue helper to FilesController**

In `app/controllers/files_controller.rb`, add under `private`:

```ruby
  # Eagerly render a thumbnail for a file whose bytes just landed. Backend-neutral: content_token
  # is the per-backend content id that keys maker_previews.version_id, so a new content supersedes.
  # Never raises into the request -- a preview is best-effort UX, not part of the write's success.
  def enqueue_preview(node_id:, name:)
    info = FileLayer.current.stat(current_user, node_id:)
    return unless info&.content_token

    ::Maker::Previews::Enqueue.call(user: current_user, node_id:, name:, version_id: info.content_token)
  rescue FileLayer::NotFound, FileLayer::FetchError
    nil # the file may have vanished/unmounted between write and here; the scan will catch up
  end
```

- [ ] **Step 2: Call it from the share/s3 upload (`create`)**

In `FilesController#create`, after the `write` line and before the redirect:

```ruby
  def create
    upload = params.require(:file)
    info = FileLayer.current.write(current_user, parent_node_id: params[:parent_node_id],
                                   name: upload.original_filename, io: upload)
    enqueue_preview(node_id: info.node_id, name: upload.original_filename)
    redirect_to file_path(info.node_id), notice: "Uploaded #{upload.original_filename}."
  end
```

- [ ] **Step 3: Call it from the chunk upload (`finalize_upload`)**

In `FilesController#finalize_upload`, after `LibraryChannel.broadcast_change` and before `render json:`:

```ruby
    node = current_user.nodes.find_by(node_id: version.node_id)
    enqueue_preview(node_id: version.node_id, name: node&.name || version.node_id) if node
```

- [ ] **Step 4: Write a web-seam test**

```ruby
# test/controllers/files_preview_enqueue_test.rb
require "test_helper"

class FilesPreviewEnqueueTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "web@example.com", password: "password12345")
    sign_in_as(@user) # use the app's existing session-login test helper (see other controller tests)
  end

  test "share/s3 upload enqueues a thumbnail for a renderable file" do
    skip "web upload seam runs on port_writable backends" unless FileLayer.current.capabilities.port_writable?

    file = fixture_file_upload("square.svg", "image/svg+xml")
    assert_enqueued_with(job: Maker::GeneratePreviewJob) do
      post files_path, params: { file: }
    end
  end
end
```

Note: match `sign_in_as` / login to however the existing `test/controllers/files_controller_test.rb` authenticates; copy that setup verbatim rather than inventing one.

- [ ] **Step 5: Run the web-seam test on each writable backend**

Run: `LIBRARY_BACKEND=share bin/rails test test/controllers/files_preview_enqueue_test.rb`
Run: `LIBRARY_BACKEND=s3 bin/rails test test/controllers/files_preview_enqueue_test.rb`
Expected: PASS (skips on chunk, which uses the two-phase flow).

- [ ] **Step 6: Wire the API commit seam**

In `app/controllers/v1/commits_controller.rb#finalize`, after `LibraryChannel.broadcast_change` and before `render json:`:

```ruby
      node = current_user.nodes.find_by(node_id: version.node_id)
      if node
        ::Maker::Previews::Enqueue.call(user: current_user, node_id: version.node_id,
                                        name: node.name, version_id: version.version_id)
      end
```

- [ ] **Step 7: Add an API-commit-seam test**

In the existing commits integration test (find it: `ls test/integration/v1 | grep -i commit`, else `test/controllers/v1/commits_controller_test.rb`), add a test that a successful finalize of a renderable file enqueues `GeneratePreviewJob`. Model the commit begin/finalize calls on the existing passing test in that file; wrap the finalize in `assert_enqueued_with(job: Maker::GeneratePreviewJob)`. Use a `.stl` or `.svg` name so the Registry resolves a renderer.

- [ ] **Step 8: Wire the scan seam (share/s3)**

In `app/services/library/reconciler.rb`, at the end of `create_or_revive!` (after the node is created/revived), enqueue for the resulting node. Read the method first (around line 474) to get the exact local variable for the node and its name/storage_path. Add, using the node just created/revived (call it `node`) and the observation `o`:

```ruby
      # Eagerly render a thumbnail for a file the scan just brought into the catalog. Best-effort;
      # a render failure must never fail the scan (which is tombstoning/reviving the whole library).
      begin
        ident = @user.maker_previews # namespace guard; see Enqueue -- no-op if no renderer
        Maker::Previews::Enqueue.call(user: @user, node_id: node.node_id,
                                      name: File.basename(o.rel_path), version_id: hash)
      rescue StandardError
        nil
      end
```

Note: `hash` is the content hash the Reconciler already computed for `o` (it is `content_token` for the share/s3 port — the same value stat returns), and `node` is the created/revived record. Confirm both names against the actual method body; adjust if the locals are named differently. Remove the stray `ident = ...` line if the method already has the node in scope — it is only a reminder that Enqueue self-guards on renderer presence.

- [ ] **Step 9: Add a Reconciler-seam test**

In the existing reconciler test (`test/services/library/reconciler_test.rb`), add a test: after a scan that creates a new renderable file (e.g. a `part.stl` observation), `Maker::GeneratePreviewJob` is enqueued for it. Use `assert_enqueued_with(job: Maker::GeneratePreviewJob)` around the scan call, matching the existing test's scan setup.

- [ ] **Step 10: Run the full preview + seam suite on all three backends**

Run: `bin/rails test test/services/maker test/jobs/maker test/controllers/files_preview_enqueue_test.rb test/services/library/reconciler_test.rb`
Run: `LIBRARY_BACKEND=share bin/rails test test/services/library/reconciler_test.rb test/controllers/files_preview_enqueue_test.rb`
Run: `LIBRARY_BACKEND=s3 bin/rails test test/services/library/reconciler_test.rb test/controllers/files_preview_enqueue_test.rb`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add app/controllers/files_controller.rb app/controllers/v1/commits_controller.rb app/services/library/reconciler.rb test/controllers/files_preview_enqueue_test.rb test/services/library/reconciler_test.rb test/integration/v1
git commit -m "feat(previews): eagerly enqueue thumbnails on upload, API commit, and scan"
```

---

## Task 7: Web grid thumbnails

**Files:**
- Modify: `app/controllers/files_controller.rb` (`index`, new `thumbnails` JSON action)
- Modify: `config/routes.rb` (a `thumbnails` collection route on files)
- Modify: `app/views/files/index.html.erb`
- Create: `app/javascript/controllers/thumbs_controller.js`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/controllers/files_controller_test.rb` (extend)

- [ ] **Step 1: Load the current-version thumbnails in `index`**

In `FilesController#index`, after the `@info_by_node` line and the `select!`, add a batched preview load keyed by `[node_id, content_token]`:

```ruby
    # Current-version thumbnail per node, in ONE query (never N+1). Keyed by [node_id, version_id]
    # where version_id is the content_token @info_by_node already carries, so we show the thumbnail
    # for the version on screen, not a stale one.
    tokens = @nodes.map { |n| @info_by_node[n.node_id]&.content_token }.compact
    @thumb_by_node = current_user.maker_previews
                       .where(kind: "thumbnail", node_id: @nodes.map(&:node_id), version_id: tokens)
                       .index_by { |p| [ p.node_id, p.version_id ] }
```

- [ ] **Step 2: Add a `thumbnails` JSON action + a small helper for the current preview**

In `FilesController`, add a public action (before `private`):

```ruby
  # GET /files/thumbnails?ids=a,b,c (JSON) — the current-version thumbnail state for each node id,
  # for the grid's poll-until-ready. Session-authed (this is the web UI, not the device-token v1
  # API), user-scoped. Shape: { "<node_id>": { status:, url: } }.
  def thumbnails
    ids = params[:ids].to_s.split(",").first(200) # bound the batch
    nodes = current_user.nodes.present.where(node_id: ids)
    info = FileLayer.current.stat_all(current_user, node_ids: nodes.map(&:node_id))
    tokens = nodes.filter_map { |n| info[n.node_id]&.content_token }
    previews = current_user.maker_previews
                 .where(kind: "thumbnail", node_id: nodes.map(&:node_id), version_id: tokens)
                 .index_by { |p| [ p.node_id, p.version_id ] }

    out = nodes.each_with_object({}) do |n, h|
      token = info[n.node_id]&.content_token
      p = token && previews[[ n.node_id, token ]]
      next unless p
      h[n.node_id] = { status: p.status, url: (p.status == "ready" && p.asset.attached? ? url_for(p.asset) : nil) }
    end
    render json: out
  end
```

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the `resources :files` block (find it near `begin_upload`/`rescan`), add a collection route:

```ruby
      get :thumbnails, on: :collection
```

If `files` is declared as bare `resources :files do ... end`, add it inside that block alongside the existing `begin_upload`/`finalize_upload`/`rescan` member/collection routes. Verify with `bin/rails routes | grep thumbnails`.

- [ ] **Step 4: Render the thumbnail cell in the grid**

In `app/views/files/index.html.erb`, change the file name cell (the `<% if node.file? %>` branch inside the Name `<td>`) to include a thumbnail. Replace:

```erb
            <% if node.file? %>
              <%= link_to node.name, file_path(node.node_id) %>
```

with:

```erb
            <% if node.file? %>
              <% info = @info_by_node[node.node_id] %>
              <% thumb = info&.content_token && @thumb_by_node[[ node.node_id, info.content_token ]] %>
              <%= link_to file_path(node.node_id), class: "file-cell",
                          data: { thumbs_target: "cell", node_id: node.node_id } do %>
                <span class="thumb" data-thumbs-target="thumb">
                  <% if thumb&.status == "ready" && thumb.asset.attached? %>
                    <img src="<%= url_for(thumb.asset) %>" alt="" loading="lazy">
                  <% elsif thumb.nil? || %w[pending processing].include?(thumb&.status) %>
                    <span class="thumb-spinner" aria-hidden="true"></span>
                  <% else %>
                    <span class="thumb-icon" aria-hidden="true"><%= File.extname(node.name).delete(".").upcase.first(4) %></span>
                  <% end %>
                </span>
                <span class="file-name"><%= node.name %></span>
              <% end %>
```

Then wrap the `<table class="files">` (or its `<tbody>`) so the Stimulus controller can find pending cells. Add to the `<table>` tag: `data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>"`.

- [ ] **Step 5: Add the poll Stimulus controller**

```javascript
// app/javascript/controllers/thumbs_controller.js
import { Controller } from "@hotwired/stimulus"

// Polls the web thumbnails endpoint for cells whose thumbnail isn't ready yet, and swaps the
// spinner for the image when it lands. Stops when nothing is pending (or after a bounded number
// of tries), so a permanently-unsupported file doesn't poll forever.
export default class extends Controller {
  static values = { url: String }
  static targets = ["cell"]

  connect() {
    this.tries = 0
    this.poll()
  }

  disconnect() { clearTimeout(this.timer) }

  pendingIds() {
    return this.cellTargets
      .filter((c) => c.querySelector(".thumb-spinner"))
      .map((c) => c.dataset.nodeId)
  }

  async poll() {
    const ids = this.pendingIds()
    if (ids.length === 0 || this.tries > 40) return
    this.tries += 1

    try {
      const res = await fetch(`${this.urlValue}?ids=${encodeURIComponent(ids.join(","))}`, {
        headers: { Accept: "application/json" },
      })
      if (res.ok) {
        const data = await res.json()
        for (const cell of this.cellTargets) {
          const entry = data[cell.dataset.nodeId]
          if (entry && entry.status === "ready" && entry.url) this.setImage(cell, entry.url)
        }
      }
    } catch (_e) { /* transient; try again below */ }

    this.timer = setTimeout(() => this.poll(), 2000)
  }

  setImage(cell, url) {
    const thumb = cell.querySelector(".thumb")
    if (!thumb || thumb.querySelector("img")) return
    const img = document.createElement("img")
    img.src = url
    img.loading = "lazy"
    img.alt = ""
    thumb.innerHTML = ""
    thumb.appendChild(img)
  }
}
```

- [ ] **Step 6: Style the thumbnails**

Append to `app/assets/stylesheets/application.css`:

```css
.file-cell { display: flex; align-items: center; gap: 10px; }
.thumb { width: 40px; height: 40px; flex: 0 0 40px; display: flex; align-items: center; justify-content: center;
         border: 1px solid var(--line); border-radius: 6px; overflow: hidden; background: #f6f6f6; }
.thumb img { width: 100%; height: 100%; object-fit: contain; }
.thumb-icon { font-size: 10px; color: var(--muted, #888); font-weight: 600; }
.thumb-spinner { width: 14px; height: 14px; border: 2px solid #ccc; border-top-color: #666;
                 border-radius: 50%; animation: thumb-spin 0.8s linear infinite; }
@keyframes thumb-spin { to { transform: rotate(360deg); } }
```

- [ ] **Step 7: Add a controller test for the thumbnails endpoint**

In `test/controllers/files_controller_test.rb`, add a test (copy the file's existing login/setup): create a node with a `ready` thumbnail preview whose `version_id` matches the node's `content_token`, then `get thumbnails_files_path, params: { ids: node_id }` and assert the JSON has `node_id => { status: "ready", url: <present> }`. If constructing a real content_token is awkward in the test backend, assert the weaker invariant: the endpoint returns 200 and a JSON object, and a node with no preview is absent from the payload.

- [ ] **Step 8: Run the web tests + verify the route**

Run: `bin/rails routes | grep thumbnails`
Expected: `GET /files/thumbnails`.
Run: `bin/rails test test/controllers/files_controller_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/files_controller.rb config/routes.rb app/views/files/index.html.erb app/javascript/controllers/thumbs_controller.js app/assets/stylesheets/application.css test/controllers/files_controller_test.rb
git commit -m "feat(web): thumbnails in the file grid with poll-until-ready"
```

---

## Task 8: Detail-view thumbnail

**Files:**
- Modify: `app/controllers/files_controller.rb` (`show`, `preview_kind`)
- Modify: `app/views/files/show.html.erb`

- [ ] **Step 1: Load the current thumbnail in `show` and add a `:thumbnail` kind**

In `FilesController#show`, after `@info = ...`, add:

```ruby
    token = @info&.content_token
    @thumbnail = token && current_user.maker_previews
                            .find_by(node_id: @node.node_id, version_id: token, kind: "thumbnail")
```

Change `preview_kind` so a registry-renderable, non-image/non-text file becomes `:thumbnail`:

```ruby
  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    return :image if %w[png jpg jpeg gif webp svg bmp ico].include?(ext)
    return :text  if %w[txt md markdown csv json xml yml yaml log rb js ts py rs go
                        c h cpp html css toml ini cfg conf sh gcode].include?(ext)
    return :thumbnail if Maker::Previews::Registry.for(ext) # stl, 3mf, dxf, lbrn2, step, obj, ...
    :other
  end
```

Note: `.svg` stays `:image` here only for the *raw* inline path — but the web layer forces SVG to download and never inlines it. That is unchanged and out of scope; the thumbnail path covers svg via the grid. Do not alter the `:image` branch.

- [ ] **Step 2: Render the `:thumbnail` branch in the detail view**

In `app/views/files/show.html.erb`, inside the `<div class="preview">`, add a branch before the final `<% else %>`:

```erb
  <% elsif @kind == :thumbnail && @thumbnail&.status == "ready" && @thumbnail.asset.attached? %>
    <img src="<%= url_for(@thumbnail.asset) %>" alt="Preview of <%= @node.name %>" class="preview-image">
  <% elsif @kind == :thumbnail && %w[pending processing].include?(@thumbnail&.status) %>
    <div class="preview-fallback muted">
      <p>Generating preview…</p>
    </div>
```

Leave the existing `:image`, `:text`, and final `:other`/fallback branches unchanged. (An `unsupported`/`failed`/absent thumbnail falls through to the existing "No inline preview" fallback, which already offers a download.)

- [ ] **Step 3: Run the show view test**

Run: `bin/rails test test/controllers/files_controller_test.rb`
Expected: PASS. If there is a system/integration test that renders `show` for a `.stl`/`.3mf` node, confirm it no longer asserts "No inline preview" for a file that now has a ready thumbnail.

- [ ] **Step 4: Manual smoke (optional but recommended)**

Boot the app (`bin/rails server`), upload a `.stl` or `.3mf`, open the file grid and the file's detail page; confirm the thumbnail appears (spinner → image) and no console errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/files_controller.rb app/views/files/show.html.erb
git commit -m "feat(web): show the rendered thumbnail on the file detail page"
```

---

## Task 9: Deploy resvg (Docker image + CI runners)

**Files:**
- Modify: `Dockerfile`
- Modify: the CI workflow(s) that run `bin/rails test` on the self-hosted Linux runner

- [ ] **Step 1: Add a resvg build stage + copy it into the runtime image**

In `Dockerfile`, after the `stl-thumbnailer` stage (around line 64), add a resvg stage:

```dockerfile
# ---- resvg: SVG→PNG rasterizer (Rust, MPL-2.0/Apache — permissive, CLAUDE.md §9). A single
# static binary, NO GPU/OpenGL/Mesa. Powers the SVG/DXF/LightBurn thumbnail path
# (Maker::Previews::SvgRasterizer). Built here, copied to PATH in the final stage.
FROM docker.io/library/rust:1-slim AS resvg
RUN cargo install resvg --version 0.47.0 --root /out --locked
```

Then in the **final stage**, after the `stl-thumbnailer` COPY (around line 81), add:

```dockerfile
# The resvg binary on PATH → Maker::Previews::SvgRasterizer#available? is true on the server,
# so SVG/DXF/LightBurn uploads get a PNG thumbnail.
COPY --from=resvg /out/bin/resvg /usr/local/bin/resvg
```

- [ ] **Step 2: Verify the image builds and resvg is on PATH**

Run: `docker build -t tinkerex-preview-check . ` (or the repo's usual build command)
Then: `docker run --rm tinkerex-preview-check resvg --version`
Expected: prints resvg 0.47.0. (If `cargo install resvg` needs system libs in the slim image, add them to the resvg stage — resvg is pure Rust and should not, but if the build errors on a missing lib, `apt-get install -y --no-install-recommends pkg-config` in that stage and retry.)

- [ ] **Step 3: Install resvg on the self-hosted CI runner (idempotent)**

Find the workflow that runs the server suite on Linux (`grep -rl "bin/rails test" .github/workflows`). In the job's dependency-install step (the same place apt/gem deps are set up), add an idempotent resvg install, e.g.:

```yaml
      - name: Ensure resvg (SVG→PNG for preview tests)
        run: |
          if ! command -v resvg >/dev/null 2>&1; then
            cargo install resvg --version 0.47.0 --locked
          fi
```

Per CLAUDE.md §15, the runner is self-hosted and persistent — keep the step a no-op when resvg is already present. Add the equivalent (`brew install resvg` guarded by `command -v`) to the macOS runner's setup if that runner also runs the preview suite.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile .github/workflows
git commit -m "build(previews): ship resvg in the image and CI so SVG/DXF/LightBurn render"
```

---

## Task 10: Document the extension path

**Files:**
- Create: `docs/adding-a-preview-format.md`

- [ ] **Step 1: Write the doc**

```markdown
# Adding a preview format

The preview system renders a file's bytes to a **PNG thumbnail** behind a small seam. Adding a
format is four steps.

1. **Write a renderer** in `app/services/maker/previews/<ext>.rb`. It responds to:
   - `available?` → Boolean — is the toolchain present? (Pure-Ruby renderers return `true`.)
   - `EXTENSIONS` → array of lowercase extensions it claims.
   - `render(bytes, size:) → { bytes:, content_type:, width:, height: }` — `content_type` must be
     an **inline-safe raster type** (`image/png` in almost all cases). If your source is 2D vector,
     build an SVG and hand it to `Maker::Previews::SvgRasterizer.to_png` (that is what `Dxf`/`Lbrn2`
     do) — do not emit `image/svg+xml`, the web layer will not inline it.
   - Raise a renderer-specific error (e.g. `RenderError`) on bad input, never a bare crash.

2. **Register it** — one line in `app/services/maker/previews/registry.rb` (`"<ext>" => Renderer`).

3. **Add a fixture** — a small valid file at `test/fixtures/files/<sample>.<ext>`, and add the
   renderer → fixture pair to `FIXTURES` in
   `test/services/maker/previews/renderer_contract_test.rb`. The shared contract test now exercises
   your renderer automatically (interface, EXTENSIONS resolve back, inline-safe raster output).

4. **If it needs a binary**, gate `available?` on it (with a `<NAME>_BIN` env override), install it
   in the `Dockerfile` (a build stage + a COPY, like `stl-thumbnailer`/`resvg`), and add an
   idempotent install to the self-hosted CI runner. A box without the binary degrades that format
   to `unsupported` (a non-error terminal state) — never a crash.

Thumbnails generate eagerly: `Maker::Previews::Enqueue.call(...)` fires from the upload, API-commit,
and scan seams, so no extra wiring is needed once the renderer is registered. Licensing: permissive
only (CLAUDE.md §9) — no GPL/AGPL toolchains in shipped artifacts.
```

- [ ] **Step 2: Commit**

```bash
git add docs/adding-a-preview-format.md
git commit -m "docs(previews): how to add a preview format"
```

---

## Final verification

- [ ] **Step 1: Full suite, all three backends**

Run: `bin/rails test`
Run: `LIBRARY_BACKEND=share bin/rails test`
Run: `LIBRARY_BACKEND=s3 bin/rails test`
Expected: all green (identical counts modulo backend-specific skips).

- [ ] **Step 2: Confirm the maker/file-layer split grep still holds (§10 tripwire)**

Run: `grep -rn "Sync::\|changelog\|manifest_chunks" app/services/maker/previews/ | grep -v ':[0-9]*: *#'`
Expected: nothing (the preview layer never reaches into sync internals; comments are excluded).

- [ ] **Step 3: Update STATUS + CLAUDE.md if the architecture moved**

Add a short note to `docs/STATUS.md` (and CLAUDE.md §3's preview row if present) that server-side PNG thumbnails now render eagerly for STL/3MF/SVG/DXF/LightBurn and surface in the web grid + detail view; STEP/OBJ/IGES remain `unsupported` in-deploy (no F3D). Commit.

---

## Self-review notes (author)

- **Spec coverage:** §2 existing engine (build-on, not rebuild) → Tasks 1–5; §4 renderer contract → Task 4; §5 PNG normalization + resvg → Tasks 1–2; §6 eager lifecycle → Tasks 5–6; §7 web UI → Tasks 7–8; §8 deploy/degradation → Task 9; §4 docs → Task 10. STEP-deferred is honored (Mesh stays registered, no F3D in Docker).
- **Type consistency:** `Enqueue.call(user:, node_id:, name:, version_id:, kind:)` used identically in Tasks 5, 6, and the v1 controller. `version_id` = `FileInfo#content_token` everywhere. Renderer contract: `render(bytes, size:, [ext:])` → `{ bytes:, content_type:, width:, height: }`, consistent with the existing job's `render_with`.
- **Known adaptation points (verify against real code, not guesses):** the exact login helper in controller tests (Task 6/7); the exact local variable names in `Reconciler#create_or_revive!` (Task 6 step 8); the `resources :files` route block shape (Task 7 step 3); the v1 previews test's status-code assertions (Task 5 step 6). Each step says to reconcile with the actual file rather than assume.
```
