# The landing's format wall — implementation plan

> **For agentic workers:** execute with **`/execute-plan`** (`.claude/commands/execute-plan.md`,
> this repo's default for subagent execution, CLAUDE.md §15), or `superpowers:executing-plans`
> inline. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks 3 and 4 reach the owner's Unraid
> box (`kamal1@192.168.1.95`, read-only) and Docker on this Mac; run them in the main session or a
> subagent with that access.

**Goal:** On tinkerex.com, `/` becomes a real landing — a headline, Try the demo, a wall of the app's own
renders of twelve files from the owner's real `catan` project, how it works, four feature rows with crops, a self-hosting band — while every
other deployment's signed-out `/` becomes the plain sign-in card.

**Spec:** `docs/superpowers/specs/2026-10-16-landing-format-wall-design.md` (read it first).

**Architecture:** A request-time route constraint on demo mode (`Tinkerex::Landing.enabled?`) sends
signed-out `/` to `LandingsController` (on `ActionController::Base`, outside the
`authenticate_user!` tree) or to Devise's sign-in. `Tinkerex::Landing` owns the twelve tiles and
renders them through `Maker::Previews::Registry` — whose `available_for?`/`render` move there from
`GeneratePreviewJob` so both callers render identically — into committed PNGs. The whole `catan`
project (a laser-cut board-game set, copied from the share library) joins `db/seeds/demo`, so the
demo a visitor clicks into holds the same files the wall shows.

**Tech stack:** Rails 8, ERB, Propshaft, layered CSS (`@layer pages`), Minitest + Capybara/Selenium,
Docker (linux/amd64 production image).

**Shells:** each step may run in a fresh shell; where a step uses `$SCRATCH`, first run
`SCRATCH=/private/tmp/claude-501/-Users-charlesschwartz-Desktop-repos-tinkerex/f86c5a0d-c00f-4601-8d5c-6a81e58c59f3/scratchpad`
(this session's scratchpad; any scratch directory outside the repo will do).

**Repo rules that bind this plan:** `docs/invariants/design-system.md` (read before touching CSS,
the layout or any template), CLAUDE.md §14d/§15. Memory-backed gotchas: bare `bin/rails test`
needs `LIBRARY_PATH=$(mktemp -d)`; never put a backtick in a `git commit -m` (use `-F file`); run
repo-editing Ruby one-liners with `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8`; after restoring a
mutation, `rm -rf tmp/cache/bootsnap*` before the green run.

---

## File map

| file | change | responsibility |
|---|---|---|
| `app/services/maker/previews/registry.rb` | modify | gains `available_for?(renderer, kind)` and `render(renderer, bytes, ext:, kind:, size:)` |
| `app/jobs/maker/generate_preview_job.rb` | modify | calls the two Registry functions; its private copies go |
| `app/services/maker/previews/{svg,dxf,lbrn2}.rb` | modify | comments that cite `GeneratePreviewJob#available_for?` cite the Registry |
| `lib/tinkerex/landing.rb` | create | `enabled?`, `TILES`, URLs, `render_wall` |
| `lib/tasks/landing.rake` | create | `bin/rails "landing:wall[seed,out]"` |
| `script/landing/capture_crops.rb` | create | photographs the four feature crops |
| `db/seeds/demo/Projects/catan/**`, `Welcome.md` | create/modify | the owner's `catan` project, whole (60 files, ~61 MB), a robber credit, a welcome line |
| `app/assets/images/landing/wall/*.png` | create | the twelve rendered tiles |
| `app/assets/images/landing/{viewer,measure,project,boxes}.jpg` | create/replace | the four crops; `library.jpg` deleted |
| `config/routes.rb` | modify | the landing's route before the card's |
| `app/controllers/landings_controller.rb` | create | renders the landing |
| `app/views/landings/show.html.erb` | create | the page |
| `app/views/users/sessions/new.html.erb` | modify | back to the plain card |
| `app/assets/stylesheets/pages/landing.css` | rewrite | the page's layout |
| tests | modify/create | see each task |
| `docs/invariants/design-system.md` | modify | rule 15 rewritten |

Dependencies: 1 → 2 → 4 → 5 → 6 → 7 → 8. Task 3 runs beside 1–2. Task 5's
view cannot render until Task 4 has committed the wall PNGs and the crops (Propshaft raises on a
missing asset).

---

## Task 1: The Registry answers the job's two questions

**Files:**
- Modify: `app/services/maker/previews/registry.rb` (append before the module's closing `end`s)
- Modify: `app/jobs/maker/generate_preview_job.rb:107`, `:111`, delete `:182-213`
- Modify: comments in `app/services/maker/previews/svg.rb:19`, `dxf.rb:39`, `dxf.rb:66`, `lbrn2.rb:142-143`
- Test: `test/services/maker/previews/registry_test.rb`

- [ ] **Step 1: Write the failing tests** — append inside `class RegistryTest`:

```ruby
      # THE JOB'S TWO QUESTIONS LIVE HERE (2026-10-16), so a second caller -- Tinkerex::Landing,
      # which renders the landing's wall -- draws exactly what the library would for the same file.
      test "render passes ext: and kind: only to a renderer whose signature declares them" do
        seen = {}
        plain = Module.new
        plain.define_singleton_method(:render) { |bytes, size:| seen[:plain] = { bytes:, size: } }
        full = Module.new
        full.define_singleton_method(:render) { |_bytes, size:, ext: nil, kind: "thumbnail"| seen[:full] = { size:, ext:, kind: } }

        Maker::Previews::Registry.render(plain, "b", ext: "stl", kind: "thumbnail", size: 64)
        Maker::Previews::Registry.render(full, "b", ext: "step", kind: "geometry")

        assert_equal({ bytes: "b", size: 64 }, seen[:plain])
        assert_equal({ size: 512, ext: "step", kind: "geometry" }, seen[:full])
      end

      test "available_for? asks a kind-aware renderer about the kind and any other about itself" do
        aware = Module.new
        aware.define_singleton_method(:available_for?) { |kind| kind == "geometry" }
        aware.define_singleton_method(:available?) { false }
        plain = Module.new
        plain.define_singleton_method(:available?) { true }

        assert Maker::Previews::Registry.available_for?(aware, "geometry")
        assert_not Maker::Previews::Registry.available_for?(aware, "thumbnail")
        assert Maker::Previews::Registry.available_for?(plain, "anything")
      end
```

- [ ] **Step 2: Run them to see them fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/registry_test.rb`
Expected: 2 errors, `NoMethodError: undefined method 'render'` / `'available_for?'` for `Maker::Previews::Registry`.

- [ ] **Step 3: Add the two functions to the Registry** — insert after `text_by_basename`'s `end`
  (still inside `module Registry`, under its `module_function`):

```ruby

      # IS THIS RENDERER ABLE TO BUILD **THIS KIND** ON THIS BOX? Asked by GeneratePreviewJob before
      # every render and by Tinkerex::Landing before every wall tile -- one answer, so the landing
      # can never show a tile the library would have marked `unsupported`.
      #
      # `available?` asks about the TOOLCHAIN, and for the 2D vector formats that toolchain is resvg
      # — because their THUMBNAIL is a rasterized SVG. The Measure payload from the same renderers is
      # Nokogiri and arithmetic and needs nothing external, so a single `available?` gate marks a
      # perfectly measurable .svg/.dxf/.lbrn2 `unsupported` on any box without the rasterizer. That
      # reads to a user as "we cannot handle this file", which is false, and it would have made the
      # measure feature silently backend-dependent: `Mage.available?` is unconditionally true, so
      # .mage would measure on such a box while the other three did not.
      #
      # `respond_to?` WITH A FALLBACK TO `available?`, the same shape `Enqueue.revision_for` already
      # uses for `payload_revision` — so the ten renderers that produce only a thumbnail are
      # untouched and the registry's published contract (available?/render/EXTENSIONS) still holds.
      def available_for?(renderer, kind)
        return renderer.available_for?(kind) if renderer.respond_to?(:available_for?)

        renderer.available?
      end

      # Renderers share a `render(bytes, size:)` contract; some (e.g. Mesh/F3D) also accept
      # `ext:` (to pick the loader) and `kind:`. Accepting `kind:` is not a promise to produce
      # every kind — Mesh takes it only to REFUSE `model_glb` (f3d renders rasters and cannot
      # export GLB), raising Unsupported, which GeneratePreviewJob maps to that terminal status.
      # Pass each kwarg only when the renderer's signature declares it, so the simpler
      # renderers stay unchanged.
      def render(renderer, bytes, ext:, kind:, size: 512)
        accepted = renderer.method(:render).parameters.select { |t, _| %i[key keyreq].include?(t) }.map(&:last)
        opts = { size: }
        opts[:ext]  = ext  if accepted.include?(:ext)
        opts[:kind] = kind if accepted.include?(:kind)
        renderer.render(bytes, **opts)
      end
```

- [ ] **Step 4: Point the job at them and delete its copies.** In `generate_preview_job.rb`:
  - line 107: `unless available_for?(renderer, preview.kind)` → `unless Maker::Previews::Registry.available_for?(renderer, preview.kind)`
  - line 111: `result = render_with(renderer, bytes, ext:, kind: preview.kind)` → `result = Maker::Previews::Registry.render(renderer, bytes, ext:, kind: preview.kind)`
  - delete everything from the line `    # IS THIS RENDERER ABLE TO BUILD **THIS KIND** ON THIS BOX?` through the `end` of `def render_with` (the blank line before `    def asset_ext(content_type)` stays).

- [ ] **Step 5: Re-point the four comments** that cite the job's method:

```bash
LANG=en_US.UTF-8 ruby -Eutf-8:utf-8 -e '
{ "app/services/maker/previews/svg.rb" => [["`GeneratePreviewJob#available_for?`", "`Maker::Previews::Registry.available_for?`"]],
  "app/services/maker/previews/dxf.rb" => [["`GeneratePreviewJob#available_for?`", "`Maker::Previews::Registry.available_for?`"]],
  "app/services/maker/previews/lbrn2.rb" => [["`GeneratePreviewJob\n      # #available_for?`", "`Maker::Previews::Registry\n      # .available_for?`"]] }.each do |path, subs|
  s = File.read(path)
  subs.each { |a, b| abort "missing in #{path}: #{a}" unless s.include?(a); s = s.gsub(a) { b } }
  File.write(path, s)
end'
grep -rn "GeneratePreviewJob#available_for\|GeneratePreviewJob$" app/services/maker/previews/ || echo "no stale citations"
```

Expected: `no stale citations`.

- [ ] **Step 6: Run the registry, job and renderer tests**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/registry_test.rb test/jobs test/services/maker/previews/renderer_contract_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews app/jobs/maker/generate_preview_job.rb test/services/maker/previews/registry_test.rb
printf '%s\n' "The preview Registry answers which renderer is available and how to call it" "" \
  "GeneratePreviewJob asked both privately; the landing's wall needs the same two answers, so they" \
  "move to Maker::Previews::Registry and the job calls them there." "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

---

## Task 2: `Tinkerex::Landing` and `bin/rails landing:wall`

**Files:**
- Create: `lib/tinkerex/landing.rb`, `lib/tasks/landing.rake`
- Test: `test/lib/landing_wall_test.rb`, `test/tasks/landing_tasks_test.rb`

- [ ] **Step 1: Write the failing module tests** — `test/lib/landing_wall_test.rb`:

```ruby
require "test_helper"

# THE LANDING'S WALL IS RENDERED, NEVER DRAWN (Tinkerex::Landing; spec 2026-10-16 §3). These pin the
# refusals -- a wall with a hole in it, or a tile left over from an older run, is the failure to fear
# -- and that a tile is byte-for-byte what the library's own renderer makes of the file.
class LandingWallTest < ActiveSupport::TestCase
  SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#1b1c19"/></svg>).freeze

  setup do
    @seed = Pathname(Dir.mktmpdir("seed"))
    @out = Pathname(Dir.mktmpdir("wall"))
  end

  teardown do
    FileUtils.remove_entry(@seed)
    FileUtils.remove_entry(@out)
  end

  def tile(source) = Tinkerex::Landing::Tile.new(source:, alt: "a tile")

  def seed!(rel, body)
    @seed.join(rel).dirname.mkpath
    @seed.join(rel).write(body)
  end

  test "a tile's extension and asset come from its source file's name" do
    t = tile("Projects/catan/laser/Hex Tiles.LBRN2")
    assert_equal "lbrn2", t.ext
    assert_equal "landing/wall/hex-tiles-lbrn2.png", t.asset
  end

  test "a source missing from the seed is refused by name" do
    err = assert_raises(Tinkerex::Landing::Error) do
      Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/missing.svg") ])
    end
    assert_match "Laser/missing.svg", err.message
    assert_empty @out.children
  end

  test "an extension no renderer claims is refused" do
    seed!("Laser/notes.xyz", "x")
    err = assert_raises(Tinkerex::Landing::Error) do
      Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/notes.xyz") ])
    end
    assert_match(/no preview renderer claims Laser\/notes\.xyz/, err.message)
  end

  test "a tile is the library's own render of the file, written as <name>-<ext>.png" do
    skip "resvg is not on this machine" unless Maker::Previews::Svg.available?
    seed!("Laser/a.svg", SVG)

    paths = Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/a.svg") ])

    assert_equal [ @out.join("a-svg.png") ], paths
    expected = Maker::Previews::Registry.render(Maker::Previews::Svg, SVG, ext: "svg", kind: "thumbnail",
                                                size: Tinkerex::Landing::SIZE)[:bytes]
    assert_equal expected.b, @out.join("a-svg.png").binread
  end

  test "a refused tile writes nothing, not even the tiles before it" do
    skip "resvg is not on this machine" unless Maker::Previews::Svg.available?
    seed!("Laser/a.svg", SVG)

    assert_raises(Tinkerex::Landing::Error) do
      Tinkerex::Landing.render_wall(seed_dir: @seed, out_dir: @out, tiles: [ tile("Laser/a.svg"), tile("Laser/missing.svg") ])
    end
    assert_empty @out.children, "a refused run left a partial wall behind"
  end

  test "the landing is on exactly when demo mode is" do
    prior = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
    assert_not Tinkerex::Landing.enabled?
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    assert Tinkerex::Landing.enabled?
  ensure
    prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
  end
end
```

- [ ] **Step 2: Run to see it fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/landing_wall_test.rb`
Expected: errors, `NameError: uninitialized constant Tinkerex::Landing`.

- [ ] **Step 3: Write `lib/tinkerex/landing.rb`.** The alt texts were written from the share box's
  own thumbnails of these files; Task 4 Step 3 checks each against its new render.

```ruby
module Tinkerex
  # THE MARKETING LANDING (2026-10-16; docs/superpowers/specs/2026-10-16-landing-format-wall-design.md).
  #
  # ON EXACTLY WHEN DEMO MODE IS. `/` shows the landing to a signed-out visitor only where
  # DEMO_ACCOUNT_EMAIL is set -- the public box alone (deploy_hygiene_test.rb). A self-hosted box has
  # nobody to pitch to, and the page's one action IS the demo. Read per request, never memoized, as
  # Tinkerex::Demo is: a test flips the variable between requests.
  #
  # THE WALL IS RENDERED, NEVER DRAWN. Each tile is the app's own preview of one file in the demo
  # seed, so the picture a stranger sees is the picture the library draws for that file, and the demo
  # they click into holds the same files. `render_wall` runs every tile's source through
  # Maker::Previews::Registry -- the calls GeneratePreviewJob makes -- and writes the PNGs the view
  # serves. It REFUSES rather than skips (a missing source, an extension no renderer claims, a
  # toolchain absent on this machine, a non-PNG result), and it writes NOTHING unless every tile
  # rendered: a wall with a hole in it, or one tile left over from an older run, is the failure to
  # fear. `bin/rails "landing:wall"` is the door; the recipe with every toolchain is Task 4 of
  # docs/superpowers/plans/2026-10-16-landing-format-wall.md.
  module Landing
    Error = Class.new(StandardError)

    INSTALL_URL = "https://github.com/chaim354/tinkerex/blob/main/docs/INSTALL.md".freeze
    SOURCE_URL = "https://github.com/chaim354/tinkerex".freeze

    # A tile's PNG is named for its source file, `<name>-<ext>.png`, so six LightBurn files are six
    # tiles and not one overwritten six times.
    Tile = Data.define(:source, :alt) do
      def ext = File.extname(source).delete_prefix(".").downcase
      def asset = "landing/wall/#{File.basename(source, ".*").parameterize}-#{ext}.png"
    end

    # Twice the tile's largest displayed size (about 128px), so it stays sharp on a 2x screen.
    SIZE = 256

    SEED_DIR = Rails.root.join("db/seeds/demo").freeze
    OUT_DIR = Rails.root.join("app/assets/images/landing/wall").freeze

# Twelve files from the owner's `catan` project, a laser-cut board-game set (2026-10-16). Every
# file of the project is in the demo seed; these are the twelve the wall shows.
TILES = [
  Tile.new(source: "Projects/catan/laser/hex tiles.lbrn2",
           alt: "A LightBurn file: the hex tiles for every resource, each engraved with its own pattern"),
  Tile.new(source: "Projects/catan/laser/number tokens.lbrn2",
           alt: "A LightBurn file: the number tokens, 2 to 12, with their probability dots"),
  Tile.new(source: "Projects/catan/laser/longest road.lbrn2",
           alt: "A LightBurn file: the Longest Road and Largest Army cards"),
  Tile.new(source: "Projects/catan/laser/ship token.lbrn2",
           alt: "A LightBurn file: the harbor tokens, 3:1 and 2:1, and the resource symbols"),
  Tile.new(source: "Projects/catan/laser/reference card.lbrn2",
           alt: "A LightBurn file: the building-cost reference cards"),
  Tile.new(source: "Projects/catan/laser/gamebox v7.lbrn2",
           alt: "A LightBurn file: the game box's finger-jointed panels, the lid engraved with the name"),
  Tile.new(source: "Projects/catan/design/tile.svg",
           alt: "An SVG file: the whole set laid out for cutting, tiles, tokens and cards"),
  Tile.new(source: "Projects/catan/design/tile nesting v1.svg",
           alt: "An SVG file: a hexagonal tray with slots for the cards and wells for the tokens"),
  Tile.new(source: "Projects/catan/design/jig for pieces.dxf",
           alt: "A DXF file: a hexagonal jig that holds pieces while they are engraved"),
  Tile.new(source: "Projects/catan/other/desert+any.mage",
           alt: "A MillMage file: a hexagonal frame and its pieces, for the CNC"),
  Tile.new(source: "Projects/catan/models/robber.3mf",
           alt: "A 3MF file: the robber, ready to slice"),
  Tile.new(source: "Projects/catan/models/Screenshot 2024-07-16 at 10.35.23 AM.stl",
           alt: "An STL file: a robber figure as a print mesh")
].freeze

    def self.enabled? = Tinkerex::Demo.enabled?

    # Renders every tile, THEN writes them all, so a refusal leaves the wall as it was.
    def self.render_wall(seed_dir: SEED_DIR, out_dir: OUT_DIR, tiles: TILES, size: SIZE)
      rendered = tiles.map { |tile| [ tile, render_tile(tile, seed_dir: Pathname(seed_dir), size:) ] }
      out_dir = Pathname(out_dir)
      out_dir.mkpath
      rendered.map { |tile, bytes| out_dir.join(File.basename(tile.asset)).tap { |path| path.binwrite(bytes) } }
    end

    def self.render_tile(tile, seed_dir:, size:)
      path = seed_dir.join(tile.source)
      raise Error, "#{tile.source} is not in #{seed_dir}" unless path.file?

      renderer = Maker::Previews::Registry.for_filename(path.basename.to_s)
      raise Error, "no preview renderer claims #{tile.source}" if renderer.nil?
      unless Maker::Previews::Registry.available_for?(renderer, "thumbnail")
        raise Error, "#{renderer.name}'s toolchain is not on this machine, so #{tile.source} cannot render here"
      end

      result = Maker::Previews::Registry.render(renderer, path.binread, ext: tile.ext, kind: "thumbnail", size:)
      raise Error, "#{tile.source} rendered #{result[:content_type].inspect}, not a PNG" unless result[:content_type] == "image/png"
      raise Error, "#{tile.source} rendered no bytes" if result[:bytes].to_s.empty?

      result[:bytes]
    end
  end
end
```

- [ ] **Step 4: Run the module tests**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/landing_wall_test.rb`
Expected: 0 failures, 0 errors (two skips only where resvg is missing; it is installed on this Mac).

- [ ] **Step 5: Write the failing task test** — `test/tasks/landing_tasks_test.rb`:

```ruby
require "test_helper"
require "rake"

# `bin/rails "landing:wall[seed,out]"` -- loading and re-enabling follow tinkerex_tasks_test.rb: task
# definitions load once per process, and a task runs its action only once until re-enabled. Its
# directories are rake ARGUMENTS, never environment variables: install_docs_test.rb demands an
# INSTALL.md row for any variable lib/tasks reads, and these two are not an installer's business.
class LandingTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("landing:wall")
    Rake::Task["landing:wall"].reenable
  end

  test "landing:wall stops with the reason when a tile cannot be rendered, and writes nothing" do
    Dir.mktmpdir do |seed|
      Dir.mktmpdir do |out|
        _stdout, stderr = capture_io do
          assert_raises(SystemExit) { Rake::Task["landing:wall"].invoke(seed, out) }
        end
        assert_match(/landing:wall: .+ is not in /, stderr)
        assert_empty Dir.children(out)
      end
    end
  end
end
```

- [ ] **Step 6: Run to see it fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/tasks/landing_tasks_test.rb`
Expected: error, `Don't know how to build task 'landing:wall'`.

- [ ] **Step 7: Write `lib/tasks/landing.rake`**

```ruby
# The landing's format wall (Tinkerex::Landing): every tile rendered from db/seeds/demo through the
# library's own preview renderers. Needs every renderer's toolchain -- the production image built for
# linux/amd64 has them all (docs/superpowers/plans/2026-10-16-landing-format-wall.md, Task 4).
namespace :landing do
  desc 'Render the landing\'s twelve wall tiles: bin/rails "landing:wall[SEED_DIR,OUT_DIR]" (both optional)'
  task :wall, %i[seed_dir out_dir] => :environment do |_task, args|
    paths = Tinkerex::Landing.render_wall(seed_dir: args[:seed_dir].presence || Tinkerex::Landing::SEED_DIR,
                                          out_dir: args[:out_dir].presence || Tinkerex::Landing::OUT_DIR)
    paths.each { |path| puts "wrote #{path} (#{path.size} bytes)" }
  rescue Tinkerex::Landing::Error => e
    abort "landing:wall: #{e.message}"
  end
end
```

- [ ] **Step 8: Run both test files, and the env-docs guard**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/landing_wall_test.rb test/tasks/landing_tasks_test.rb test/install_docs_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 9: Commit**

```bash
git add lib/tinkerex/landing.rb lib/tasks/landing.rake test/lib/landing_wall_test.rb test/tasks/landing_tasks_test.rb
printf '%s\n' "Tinkerex::Landing renders the wall's twelve tiles through the library's own renderers" "" \
  "It refuses a missing source, an unclaimed extension, an absent toolchain or a non-PNG result," \
  "and writes nothing unless every tile rendered. bin/rails landing:wall is the door." "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

---

## Task 3: The owner's `catan` project joins the demo seed

**Files:**
- Create: `db/seeds/demo/Projects/catan/**` (60 files, about 61 MB, copied whole without `.git`)
- Create: `db/seeds/demo/Projects/catan/models/CREDITS.md`
- Modify: `db/seeds/demo/Welcome.md`
- Modify: `test/lib/demo_reset_test.rb` (the budget, and a new names guard)

Decided with the owner on 2026-10-16: the whole project, its two large files included (a 28 MB STL
and the 17 MB `design/tile.svg`); a credit for the robber, the one file not theirs; the five
screenshots reviewed and kept (boxes.py settings pages, nothing personal).

- [ ] **Step 1: Time the seed's tests BEFORE the seed grows**, for Step 6's comparison:

```bash
/usr/bin/time -p env LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/demo_reset_test.rb \
  test/tasks/tinkerex_tasks_test.rb test/jobs/tinkerex/demo_reset_job_test.rb 2>&1 | tail -4
```

  Write down the `real` seconds.

- [ ] **Step 2: Copy the project from the share deployment** (read-only on the box; the library
  there is mounted at `/library`; `.git` is left out because a repository cannot be committed inside
  this one and the port refuses `.git` as a write destination):

```bash
mkdir -p "$SCRATCH/catan-src"
ssh kamal1@192.168.1.95 'docker exec $(docker ps -qf name=^tinkerex-web-share-) tar -C /library --exclude=.git -cf - Projects/catan' \
  | tar -C "$SCRATCH/catan-src" -xf -
rsync -a --exclude .git --exclude .DS_Store "$SCRATCH/catan-src/Projects/catan/" "db/seeds/demo/Projects/catan/"
find db/seeds/demo/Projects/catan -type f | wc -l
du -sh db/seeds/demo/Projects/catan
find db/seeds/demo/Projects/catan -name .git
```

Expected: `60`, about `61M`, and no `.git`. (The session that wrote this plan already pulled the
same tree into `$SCRATCH/catan-src` on 2026-10-16; the `ssh` line refreshes it.)

- [ ] **Step 3: Credit the robber** — write `db/seeds/demo/Projects/catan/models/CREDITS.md`:

```markdown
# Credits

`robber.3mf` is made from "Catan Robber" by doghound678 on Thingiverse
(https://www.thingiverse.com/thing:86225), licensed under Creative Commons Attribution.
Everything else in this project is its maker's own work.
```

- [ ] **Step 4: Point the welcome note at it** — in `db/seeds/demo/Welcome.md`, insert as the first
  bullet under `Things to try:`:

```markdown
- Open **Projects**, then **catan**: a maker's real laser-cut board-game set, the hex tiles, tokens,
  cards and game box in LightBurn, SVG and DXF, a MillMage file for the CNC, and the robber to
  print. It is the project the tinkerex.com front page shows.
```

- [ ] **Step 5: Raise the seed's budget and guard its names** — in `test/lib/demo_reset_test.rb`,
  replace the test `"the committed seed set stays small"` with these two:

```ruby
  # THE SEED IS THE OWNER'S WHOLE `catan` PROJECT (about 61 MB) beside the small Desk Lamp set: the
  # landing on tinkerex.com shows twelve of its files and the demo holds all of them, by the owner's
  # decision (2026-10-16; docs/superpowers/specs/2026-10-16-landing-format-wall-design.md §3). It
  # ships in the image and is rewritten every night, so the ceiling still matters: it catches a
  # whole library committed by accident.
  test "the committed seed set stays within its budget" do
    bytes = Dir.glob("**/*", base: SEED_DIR).sum { |rel| File.file?(SEED_DIR.join(rel)) ? File.size(SEED_DIR.join(rel)) : 0 }
    assert_operator bytes, :<, 70 * 1024 * 1024,
                    "db/seeds/demo ships in the image and is rewritten every night; keep it under 70 MB"
  end

  # EVERY NAME IN THE SHIPPED SEED IS ONE THE PORT ACCEPTS. The reset writes each entry through
  # mkdir/write, and a single name the doors refuse (a `.git`, a `.trash`, a slash) would fail the
  # nightly reset on the public box -- found by a visitor, not by this suite, unless this asks.
  test "every name in the shipped seed is one the doors accept" do
    names = seed_paths.flat_map { |rel| rel.split("/") }.uniq
    assert_operator names.size, :>, 20, "the scan found too few names; did SEED_DIR move?"
    refused = names.reject { |n| Maker::MoveNode.valid_leaf_name?(n) && !Library::ReservedNames.reserved?(n) }
    assert_empty refused, "the reset would refuse these seed names: #{refused.inspect}"
  end
```

- [ ] **Step 6: Time the seed's tests AFTER, and decide**

```bash
/usr/bin/time -p env LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/demo_reset_test.rb \
  test/tasks/tinkerex_tasks_test.rb test/jobs/tinkerex/demo_reset_job_test.rb 2>&1 | tail -4
```

Expected: 0 failures. **If `real` grew by more than 20 seconds** over Step 1 (every `reset!` now
writes 61 MB through the port), make `demo_reset_test.rb`'s resets use a lean copy of the seed — the
shipped seed minus `Projects/catan` — and keep the two tests above on the shipped seed. Replace its
`SEED_DIR = Rails.root.join("db/seeds/demo")` line with:

```ruby
  SHIPPED_SEED_DIR = Rails.root.join("db/seeds/demo")
  # THE RESETS RUN OVER A LEAN COPY: the shipped seed holds the owner's 61 MB `catan` project, and
  # writing it through the port on every reset! made this file slow for nothing the small set does
  # not already prove. The budget and names tests below read the SHIPPED seed.
  SEED_DIR = Pathname(Dir.mktmpdir("demo-seed")).tap do |dir|
    FileUtils.cp_r(SHIPPED_SEED_DIR.children.map(&:to_s), dir)
    FileUtils.rm_rf(dir.join("Projects/catan"))
  end
```

  and in the two Step 5 tests read `SHIPPED_SEED_DIR` instead of `SEED_DIR` (for the names test,
  `Dir.glob("**/*", base: SHIPPED_SEED_DIR)` in place of `seed_paths`). Rerun Step 6; if the task and
  job tests are what grew, say so in the PR rather than reshaping them too.

- [ ] **Step 7: Commit**

```bash
git add db/seeds/demo test/lib/demo_reset_test.rb
printf '%s\n' "The demo seed holds the owner's whole catan project, the files the landing shows" "" \
  "Sixty files of a laser-cut board-game set, copied from the share library without its .git, with a" \
  "credit for the one model that is not the owner's. The seed's budget rises to 70 MB on the owner's" \
  "word, and a new guard asks that every name in it is one the reset's doors accept." "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

---

## Task 4: Render the wall and photograph the crops, in the production image

**Files:**
- Create: `app/assets/images/landing/wall/<name>-<ext>.png`, one per `Tinkerex::Landing::TILES` entry (twelve)
- Create: `script/landing/capture_crops.rb`
- Create/replace: `app/assets/images/landing/{viewer,measure,project,boxes}.jpg`
- Modify: `test/lib/landing_wall_test.rb` (the committed-wall test)

Why the image: the tiles need every toolchain (stl-thumbnailer, F3D, pdfium, resvg, vipsthumbnail,
node), and F3D ships no arm64 build, so the image is built for linux/amd64 (Docker Desktop runs it
under Rosetta). The same running stack serves the crops, with Tools.

- [ ] **Step 1: Build the stack from this branch, demo mode on** (run in the background; the first
  amd64 build takes a while):

```bash
SCRATCH=/private/tmp/claude-501/-Users-charlesschwartz-Desktop-repos-tinkerex/f86c5a0d-c00f-4601-8d5c-6a81e58c59f3/scratchpad
mkdir -p "$SCRATCH/landing-library"
printf 'services:\n  web:\n    environment:\n      DEMO_ACCOUNT_EMAIL: demo@example.com\n' > "$SCRATCH/landing.compose.yml"
export DOCKER_DEFAULT_PLATFORM=linux/amd64 LIBRARY_HOST_PATH="$SCRATCH/landing-library" TINKEREX_PORT=8080
docker compose -p tinkerex-landing -f docker-compose.yml -f docker-compose.build.yml -f "$SCRATCH/landing.compose.yml" \
  up -d --build web boxes addons
```

Expected: three containers up; `curl -fsS localhost:8080/up` answers once the healthcheck passes.
(`../tinkerex-addons` must exist; it does on this Mac. The openscad sidecar is not needed.)

- [ ] **Step 2: Render the wall in that image**

```bash
docker run --rm --platform linux/amd64 --entrypoint "" \
  -v "$PWD/db/seeds/demo:/seed:ro" -v "$PWD/app/assets/images/landing/wall:/out" \
  -v "$SCRATCH/landing-library:/library" tinkerex:local bin/rails "landing:wall[/seed,/out]"
ls -la app/assets/images/landing/wall
```

Expected: twelve `wrote /out/<name>-<ext>.png (<n> bytes)` lines and twelve PNGs. A `landing:wall: …`
refusal names the tile and why. These are real files, so the fix is to choose ANOTHER file of the
same project for that tile in `TILES` (never to edit the file), then rerun.

- [ ] **Step 3: Look at every tile** with the Read tool (it shows PNGs). Each must read at a glance
  as what its `alt` says. Compare with the share box's own thumbnails of the same files (in
  `$SCRATCH/thumbs/`, pulled 2026-10-16) — they should match. Where a tile reads differently from
  its alt text, rewrite the ALT TEXT to describe the render; where a tile is blank or too faint to
  read at 128 px, swap that tile for another file of the project (`design/tokens-and-harbors-v1.svg`,
  `laser/numbers and harbors v1.lbrn2` and `models/pieces jig v1.3mf` are good spares) and rerun
  Step 2 — never edit a PNG.

- [ ] **Step 4: Seed the demo in the running stack**

```bash
docker compose -p tinkerex-landing exec web bin/docker-entrypoint bin/rails tinkerex:demo:setup
```

  Then wait for the previews: poll `docker compose -p tinkerex-landing exec web bin/docker-entrypoint
  bin/rails runner 'puts Maker::Preview.group(:status).count'` until nothing is `pending` (about a
  minute; the project's 28 MB STL and 17 MB SVG take longest under emulation). If it prints `{}` after a minute, nothing was indexed yet: run
  `bin/rails runner 'Library::ScanJob.perform_now(user_id: User.sole.id)'` the same way, then poll again.

- [ ] **Step 5: Write `script/landing/capture_crops.rb`**

```ruby
#!/usr/bin/env ruby
# The landing's four feature crops (docs/superpowers/specs/2026-10-16-landing-format-wall-design.md
# section 3): the app, photographed. Drives headless Chrome at device pixel ratio 2 against a running
# Tinkerex whose demo is seeded from db/seeds/demo, signs in with Try the demo, and writes one
# 1120x700 JPEG per crop into app/assets/images/landing. The demo banner is removed before each
# capture -- it is the public demo's chrome, not the app's -- and NOTHING ELSE on the page is touched.
#
#   bundle exec ruby script/landing/capture_crops.rb http://localhost:8080
#
# Needs `vips` on PATH (Homebrew's) for the JPEG encode. Retake the crops whenever the pages they
# show move; never edit the images by hand.
require "base64"
require "open3"
require "selenium-webdriver"
require "tmpdir"
require "uri"

BASE = ARGV.fetch(0) { abort "usage: capture_crops.rb BASE_URL" }.chomp("/")
OUT = File.expand_path("../../app/assets/images/landing", __dir__)
WIDTH = 1120 # the <img> width/height in app/views/landings/show.html.erb
HEIGHT = 700
ASPECT = WIDTH.fdiv(HEIGHT)

# name => [the page (a file found by name, or a path), the element to frame, how to frame it, ready?]
#   expand -- the whole element, widened or heightened around its centre to 16:10
#   top    -- the element's full width, 16:10 from its top edge
CROPS = {
  "viewer" => [ [ :file, "robber.3mf" ], ".model-viewer", "expand",
                "(document.querySelector('.model-viewer-dims')?.textContent || '').trim().length > 0" ],
  "measure" => [ [ :file, "hex tiles.lbrn2" ], ".measure-view", "expand",
                 "(document.querySelector('.measure-stage')?.childElementCount || 0) > 0" ],
  "project" => [ [ :path, "/projects/catan" ], "main#main", "top", "!!document.querySelector('.page-head')" ],
  "boxes" => [ [ :path, "/tools/boxes" ], "main#main", "top", "!!document.querySelector('main svg, main canvas')" ]
}.freeze

FRAME_JS = <<~JS.freeze
  const [selector, frame, aspect] = arguments;
  const r = document.querySelector(selector).getBoundingClientRect();
  let x = r.left + scrollX, y = r.top + scrollY, w = r.width, h = r.height;
  if (frame === "expand" && w / h < aspect) { const nw = h * aspect; x -= (nw - w) / 2; w = nw; }
  else if (frame === "expand") { const nh = w / aspect; y -= (nh - h) / 2; h = nh; }
  return { x: Math.max(0, x), y: Math.max(0, y), width: w, height: w / aspect, scale: 1 };
JS

options = Selenium::WebDriver::Chrome::Options.new(args: %w[--headless=new --window-size=1280,800 --hide-scrollbars])
driver = Selenium::WebDriver.for(:chrome, options:)
driver.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 800, deviceScaleFactor: 2, mobile: false)
wait = Selenium::WebDriver::Wait.new(timeout: 90)

begin
  driver.navigate.to "#{BASE}/"
  wait.until { driver.find_elements(xpath: "//button[normalize-space()='Try the demo']").any? }.first.click
  wait.until { driver.find_elements(css: "aside.rail").any? }

  CROPS.each do |name, (target, selector, frame, ready)|
    if target.first == :file
      driver.navigate.to "#{BASE}/files?q=#{URI.encode_www_form_component(target.last)}"
      link = wait.until do
        driver.find_elements(xpath: "//main//a[contains(@href,'/files/')][contains(normalize-space(.), \"#{target.last}\")]").first
      end
      driver.navigate.to link.attribute("href")
    else
      driver.navigate.to "#{BASE}#{target.last}"
    end
    wait.until { driver.execute_script("return #{ready}") }
    sleep 3 # a WebGL frame, the Measure stage and an addon bundle all finish drawing after "ready"
    driver.execute_script("document.querySelector('.demo-banner')?.remove(); window.scrollTo(0, 0)")
    clip = driver.execute_script(FRAME_JS, selector, frame, ASPECT)
    data = driver.execute_cdp("Page.captureScreenshot", format: "png", clip:, captureBeyondViewport: true)["data"]

    Dir.mktmpdir do |dir|
      png = File.join(dir, "#{name}.png")
      File.binwrite(png, Base64.decode64(data))
      out = File.join(OUT, "#{name}.jpg")
      _, err, status = Open3.capture3("vips", "thumbnail", png, "#{out}[Q=82,strip]", WIDTH.to_s,
                                      "--height", HEIGHT.to_s, "--size", "force")
      abort "vips failed for #{name}: #{err}" unless status.success?
      puts "wrote #{out}"
    end
  end
ensure
  driver.quit
end
```

- [ ] **Step 6: Capture, then look at each crop**

```bash
bundle exec ruby script/landing/capture_crops.rb http://localhost:8080
vipsheader app/assets/images/landing/{viewer,measure,project,boxes}.jpg
```

Expected: four `wrote` lines; each header `1120x700`. Read each JPEG: the viewer shows the robber
with its dimensions; Measure shows the hex tiles with their readout; the project page shows the
`catan` project's head and files; the box generator shows its form and a box. If a frame misses its point, change that
crop's selector or frame mode in `CROPS` and recapture — never edit an image. If a crop's content
differs from Task 5's alt text, change the alt text there to describe what the image shows.

- [ ] **Step 7: Stop the stack**

```bash
docker compose -p tinkerex-landing -f docker-compose.yml -f docker-compose.build.yml -f "$SCRATCH/landing.compose.yml" down -v
```

- [ ] **Step 8: Pin the committed wall** — append to `test/lib/landing_wall_test.rb`:

```ruby
  # THE COMMITTED WALL IS COMPLETE. Every tile names a file the seed holds and a PNG
  # `bin/rails landing:wall` wrote, so a tile added to TILES without a render -- or a sample removed
  # from the seed -- is red here before the landing renders a broken image.
  test "the wall is twelve tiles, each a seed file with a rendered PNG and alt text" do
    tiles = Tinkerex::Landing::TILES
    assert_equal 12, tiles.size
    assert_equal tiles.size, tiles.map(&:asset).uniq.size, "two tiles would write one PNG"
    tiles.each do |t|
      assert Tinkerex::Landing::SEED_DIR.join(t.source).file?, "#{t.source} is not in db/seeds/demo"
      assert Rails.root.join("app/assets/images", t.asset).file?, "#{t.asset} is not rendered: bin/rails landing:wall"
      assert_predicate t.alt, :present?
    end
  end
```

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/lib/landing_wall_test.rb`
Expected: 0 failures.

- [ ] **Step 9: Commit**

```bash
git add app/assets/images/landing script/landing/capture_crops.rb test/lib/landing_wall_test.rb
printf '%s\n' "The landing's wall tiles and feature crops, from the production image" "" \
  "Twelve tiles rendered by bin/rails landing:wall inside the linux/amd64 image, and four crops of" \
  "the seeded demo photographed by script/landing/capture_crops.rb at 2x." "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

---

## Task 5: Signed out, `/` answers by demo mode

**Files:**
- Modify: `config/routes.rb:44-55`
- Create: `app/controllers/landings_controller.rb`, `app/views/landings/show.html.erb`
- Modify: `app/views/users/sessions/new.html.erb` (back to the plain card)
- Rewrite: `app/assets/stylesheets/pages/landing.css`
- Delete: `app/assets/images/landing/library.jpg`
- Rewrite: `test/integration/web/landing_test.rb`
- Modify: `test/integration/web/auth_pages_test.rb:129-130`, `test/integration/web/demo_session_test.rb:143-146`, `:175-178`

- [ ] **Step 1: Write the failing integration test** — replace `test/integration/web/landing_test.rb`:

```ruby
require "test_helper"
require "support/public_fixture"

module Web
  # THE FRONT DOOR, SECOND PASS (2026-10-16). Signed out, `/` has two answers and DEMO MODE picks:
  # on the public demo's box (DEMO_ACCOUNT_EMAIL set) it is the marketing landing -- the pitch, a wall
  # of twelve of the app's own renders, how it works, four features, Try the demo as its one accent;
  # anywhere else it is the plain sign-in card, because a self-hosted box has nobody to pitch to.
  # /users/sign_in is the plain card in both. Signed in, `/` is Recent. config/routes.rb declares
  # three roots in an order that matters; these are what go red if it changes.
  class LandingTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as

    INSTALL_URL = Tinkerex::Landing::INSTALL_URL
    SOURCE_URL = Tinkerex::Landing::SOURCE_URL

    setup do
      # Recent (the signed-in `/`) reads the library; a fresh share root keeps every leg the same.
      @root = use_fresh_share_library!
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    teardown do
      @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo
    end

    # The only account, so on share and s3 no other library sharer closes the demo's door
    # (Tinkerex::Demo.available?).
    def demo_on!(account: true)
      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      return unless account

      User.create!(email: "demo@example.com", password: SecureRandom.base58(32),
                   confirmed_at: Time.current, handle: "demo")
    end

    test "demo mode off, / is the plain sign-in card and nothing of the landing" do
      get "/"
      assert_response :success
      assert_select "main#main.container.auth-main", 1
      assert_select ".auth-card .brand .brand-name", text: "Tinkerex"
      assert_select ".auth-card form[action=?] input[name='user[email]']", user_session_path
      assert_select ".landing", 0
    end

    test "demo mode on, / is the landing: nav, pitch, the twelve-tile wall, how it works, four features" do
      demo_on!
      get "/"
      assert_response :success

      assert_select "main#main.container.landing-main", 1
      assert_select ".landing-nav .brand .brand-name", text: "Tinkerex"
      assert_select ".landing-nav a[href=?]", INSTALL_URL, text: "Install"
      assert_select ".landing-nav a[href=?]", SOURCE_URL, text: "Source"
      assert_select ".landing-nav a[href=?]", new_user_session_path, text: "Log in"
      assert_select ".landing-hero h1", text: "Every file your workshop makes, previewed."
      # THE WALL IS THE APP'S OWN RENDERS (Tinkerex::Landing): one tile per TILES entry, each served
      # from app/assets/images/landing/wall with its alt text -- the only picture above the fold.
      assert_select ".landing-wall li", Tinkerex::Landing::TILES.size
      Tinkerex::Landing::TILES.each do |tile|
        assert_select ".landing-wall img[src^=?][alt=?]", "/assets/#{tile.asset.delete_suffix('.png')}-", tile.alt
      end
      assert_select ".landing-wall-figure figcaption", text: /one maker's laser-cut board-game set/
      assert_select ".landing-steps ol > li", 3
      assert_select ".landing-feature", 4
      assert_select ".landing-feature img[loading=lazy][width='1120'][height='700']", 4
      assert_select ".landing-feature img:not([alt])", 0
      assert_select ".landing-own li", 4
      assert_select ".landing-footer a[href=?]", new_user_session_path
      # The visitor's shell: no rail, no public header, and no sign-in form -- Log in is a link.
      assert_select "aside.rail", 0
      assert_select "header.public-header", 0
      assert_select ".auth-card", 0
    end

    # THE ACCENT IS SPENT ONCE (design-system.md rule 13), on the action this page exists for.
    test "the accent is Try the demo while the demo is available" do
      demo_on!
      get "/"
      assert_select "main .primary", 1
      assert_select ".landing-hero form[action=?] button.btn.primary", demo_session_path, text: "Try the demo"
      assert_select ".landing-hero a.btn:not(.primary)[href=?]", INSTALL_URL, text: "Install it yourself"
      assert_select ".landing-hint", text: "No sign-up. A shared account that resets every night."
      assert_select ".landing-closing form[action=?] button.btn:not(.primary)", demo_session_path
    end

    # Mid-reset, or before tinkerex:demo:setup, there is no account and POST /demo answers 404, so
    # there is no button -- and the page still spends its accent exactly once, on Install.
    test "with no demo account to sign into, Install takes the accent and no demo button renders" do
      demo_on!(account: false)
      get "/"
      assert_response :success
      assert_select "form[action=?]", demo_session_path, 0
      assert_select ".landing-hint", 0
      assert_select "main .primary", 1
      assert_select ".landing-hero a.btn.primary[href=?]", INSTALL_URL
    end

    test "the sign-in page is the plain card in both modes" do
      get new_user_session_path
      assert_select ".auth-card .brand .brand-name", text: "Tinkerex"
      assert_select ".landing", 0

      demo_on!
      get new_user_session_path
      assert_select "main#main.container.auth-main", 1
      assert_select ".auth-card form[action=?]", user_session_path
      assert_select ".landing", 0
    end

    test "signed in, / is Recent in both modes" do
      sign_in_as(make_owner!(handle: "ada"))
      get "/"
      assert_select ".page-head h1", text: "Recent"

      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      get "/"
      assert_select ".page-head h1", text: "Recent"
      assert_select ".landing", 0
    end

    test "the landing names the product for a crawler and a tab" do
      demo_on!
      get "/"
      assert_select "title", text: /Tinkerex/
      assert_select "head meta[name='description'][content*='Tinkerex']", 1
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/landing_test.rb`
Expected: failures — demo off still renders the old landing, demo on has no `.landing-nav`.

- [ ] **Step 3: Route `/` by demo mode** — in `config/routes.rb`, replace the comment block that
  begins `# THE FRONT DOOR HAS TWO ANSWERS` and the two lines after it (through `root to: "home#index"`) with:

```ruby
# THE FRONT DOOR HAS THREE ANSWERS (the landing's second pass, 2026-10-16). Signed out on the public
# demo's box (Tinkerex::Landing.enabled?, which is demo mode), `/` is the marketing landing
# (LandingsController). Signed out anywhere else it is the plain sign-in card -- a self-hosted box has
# nobody to pitch to. Signed in, `/` is Recent. `unauthenticated` is Devise's REQUEST-TIME constraint
# (Warden reads the session and the remember cookie, the question `user_signed_in?` asks); the
# landing's own constraint is read per request too, never at boot, because a test flips
# DEMO_ACCOUNT_EMAIL between requests (Tinkerex::Demo's rule). DECLARED IN THIS ORDER BECAUSE ROUTES
# MATCH IN DECLARATION ORDER: the landing first, or the card answers every visitor; both before
# `root`, or a visitor is redirected to /users/sign_in (landing_test.rb). `root` keeps its name, so
# every `root_path` still means "/" and Devise lands a sign-in and a sign-out there. `devise_scope`
# sets the mapping the sessions controller needs; the landing needs none.
unauthenticated(:user) do
  root to: "landings#show", as: :landing_root, constraints: ->(_request) { Tinkerex::Landing.enabled? }
end
devise_scope(:user) { unauthenticated(:user) { root to: "users/sessions#new", as: :unauthenticated_root } }
root to: "home#index"
```

- [ ] **Step 4: Write `app/controllers/landings_controller.rb`**

```ruby
# THE MARKETING LANDING (2026-10-16): what a stranger sees at `/` on the public demo's box, and nowhere
# else (config/routes.rb asks Tinkerex::Landing.enabled?). It stands on ActionController::Base, NOT
# ApplicationController, for the reason Public::BaseController does: every ApplicationController
# descendant must run `authenticate_user!` (architecture_invariants_test.rb), and the honest way to have
# a page nobody signs in to see is to stand outside that tree, never to skip the callback. It is NOT in
# the Public namespace either, because its Try the demo button is a form whose CSRF token writes the
# session, which `Public::` may never touch (§14d). It reads no user: the route only reaches it signed out.
class LandingsController < ActionController::Base
  layout "application"

  def show
    # One COUNT, the one the sign-in card pays (Tinkerex::Demo.available?): the demo button exists only
    # while there is an account to sign into, and Install takes the accent when there is none.
    @demo_available = Tinkerex::Demo.available?
  end
end
```

- [ ] **Step 5: Write `app/views/landings/show.html.erb`**

```erb
<%# THE LANDING, SECOND PASS (2026-10-16): the marketing page at `/` on the public demo's box, and
    nowhere else -- config/routes.rb asks Tinkerex::Landing.enabled?, which is demo mode, because a
    self-hosted box has nobody to pitch to and this page's one action IS the demo. The spec is
    docs/superpowers/specs/2026-10-16-landing-format-wall-design.md; design-system.md rule 15 holds
    the rules, and three bind every edit here:
      * THE ACCENT IS SPENT ONCE: Try the demo while there is an account to sign into, else Install
        (landing_test.rb, accent_spend_test.rb). The closing call to action repeats both, quiet.
      * THE WALL IS RENDERED, NEVER DRAWN: each tile is the app's own preview of a file in
        db/seeds/demo, written by `bin/rails landing:wall`; Tinkerex::Landing::TILES lists them.
      * THE CROPS ARE THE APP, PHOTOGRAPHED by script/landing/capture_crops.rb at 1120x700 from a demo
        seeded with the same files, the demo banner removed and nothing else touched. Retake them when
        the pages they show move; never edit them by hand.
    No script on this page: plain HTML and CSS, nothing for the CSP to nonce. %>
<% content_for :title, "Tinkerex: every file your workshop makes, previewed" %>
<% content_for :head do %>
  <meta name="description" content="Tinkerex indexes the folder your STL, STEP, LightBurn, DXF and Gerber files already live in, draws a preview of each, and opens them in the browser, measured in millimetres. Self-hosted and open source.">
<% end %>
<% content_for :container_class, "landing-main" %>
<% install_url = Tinkerex::Landing::INSTALL_URL %>
<% source_url = Tinkerex::Landing::SOURCE_URL %>

<div class="landing">
  <header class="landing-nav">
    <p class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></p>
    <nav class="landing-nav-links" aria-label="Tinkerex">
      <a href="<%= install_url %>">Install</a>
      <a href="<%= source_url %>">Source</a>
      <%= link_to "Log in", new_user_session_path %>
    </nav>
  </header>

  <section class="landing-hero" aria-labelledby="landing-title">
    <div class="landing-pitch">
      <h1 id="landing-title" class="landing-title">Every file your workshop makes, previewed.</h1>
      <p class="landing-lede">Tinkerex indexes the folder your STL, STEP, LightBurn, DXF and Gerber files already live in, draws a preview of each (more than a hundred file types), and opens them in the browser, measured in millimetres. It runs on your own box, and your files stay plain files.</p>
      <div class="landing-actions">
        <% if @demo_available %>
          <%= button_to "Try the demo", demo_session_path, class: "btn primary" %>
          <%= link_to "Install it yourself", install_url, class: "btn" %>
        <% else %>
          <%= link_to "Install it yourself", install_url, class: "btn primary" %>
        <% end %>
      </div>
      <% if @demo_available %>
        <p class="landing-hint">No sign-up. A shared account that resets every night.</p>
      <% end %>
    </div>

    <figure class="landing-wall-figure">
      <ul class="landing-wall" aria-label="Twelve files from one project, as Tinkerex previews them">
        <% Tinkerex::Landing::TILES.each do |tile| %>
          <li class="landing-tile">
            <%= image_tag tile.asset, alt: tile.alt, width: Tinkerex::Landing::SIZE, height: Tinkerex::Landing::SIZE %>
            <span class="landing-tile-ext" aria-hidden="true">.<%= tile.ext %></span>
          </li>
        <% end %>
      </ul>
      <figcaption>Twelve files from one maker's laser-cut board-game set, as Tinkerex previews them. The demo holds the whole project.</figcaption>
    </figure>
  </section>

  <section class="landing-steps" aria-labelledby="landing-steps-title">
    <h2 id="landing-steps-title" class="landing-section-title">How it works</h2>
    <ol>
      <li>
        <h3>Point it at a folder</h3>
        <p>A NAS share, an S3 bucket or a sync server. Nothing is imported or copied.</p>
      </li>
      <li>
        <h3>It keeps up on its own</h3>
        <p>Save from LightBurn, a slicer or KiCad, and the file appears within minutes.</p>
      </li>
      <li>
        <h3>Open anything, anywhere</h3>
        <p>Spin a model, measure a cut file, read a README, from any browser.</p>
      </li>
    </ol>
  </section>

  <div class="landing-features">
    <section class="landing-feature" aria-labelledby="landing-feature-viewer">
      <div class="landing-feature-text">
        <h2 id="landing-feature-viewer">A 3D viewer that speaks millimetres</h2>
        <p>STL, 3MF, STEP and a dozen more open in the browser with their size on three axes.</p>
      </div>
      <figure class="landing-feature-shot">
        <%= image_tag "landing/viewer.jpg", width: 1120, height: 700, loading: "lazy",
                      alt: "The 3D viewer: the board game's robber turned in the browser, its size in millimetres beneath it" %>
      </figure>
    </section>
    <section class="landing-feature" aria-labelledby="landing-feature-measure">
      <div class="landing-feature-text">
        <h2 id="landing-feature-measure">Cut files, measured</h2>
        <p>LightBurn, SVG and DXF files show their real size, and print at 1:1 to check against stock.</p>
      </div>
      <figure class="landing-feature-shot">
        <%= image_tag "landing/measure.jpg", width: 1120, height: 700, loading: "lazy",
                      alt: "The Measure view: the hex tiles' LightBurn file drawn to scale with its width and height" %>
      </figure>
    </section>
    <section class="landing-feature" aria-labelledby="landing-feature-project">
      <div class="landing-feature-text">
        <h2 id="landing-feature-project">A folder becomes a project</h2>
        <p>Make a folder under Projects and it gets a page: its README, its files by kind, its git repository.</p>
      </div>
      <figure class="landing-feature-shot">
        <%= image_tag "landing/project.jpg", width: 1120, height: 700, loading: "lazy",
                      alt: "A project page: the board-game set's laser files, designs and prints grouped by kind" %>
      </figure>
    </section>
    <section class="landing-feature" aria-labelledby="landing-feature-tools">
      <div class="landing-feature-text">
        <h2 id="landing-feature-tools">Generate the next file</h2>
        <p>Tools like the box generator save straight into your library, next to everything else.</p>
      </div>
      <figure class="landing-feature-shot">
        <%= image_tag "landing/boxes.jpg", width: 1120, height: 700, loading: "lazy",
                      alt: "The box generator: a box's dimensions beside its cut sheet" %>
      </figure>
    </section>
  </div>

  <section class="landing-own" aria-labelledby="landing-own-title">
    <h2 id="landing-own-title" class="landing-section-title">Yours, on your box</h2>
    <ul>
      <li><h3>Your box</h3><p>Docker on Unraid, Linux, a Mac or Windows.</p></li>
      <li><h3>Plain files</h3><p>Uninstall it and your folder is unchanged.</p></li>
      <li><h3>No database to run</h3><p>SQLite out of the box.</p></li>
      <li><h3>Apache-2.0</h3><p>Open source, every line.</p></li>
    </ul>
  </section>

  <section class="landing-closing" aria-labelledby="landing-closing-title">
    <div>
      <h2 id="landing-closing-title">See it with real files</h2>
      <p>The demo is the same app, over a small sample library.</p>
    </div>
    <div class="landing-actions">
      <% if @demo_available %>
        <%= button_to "Try the demo", demo_session_path, class: "btn" %>
      <% end %>
      <%= link_to "Install guide", install_url, class: "btn" %>
    </div>
  </section>

  <footer class="landing-footer">
    <span>Tinkerex</span>
    <span>Apache-2.0</span>
    <a href="<%= source_url %>">Source</a>
    <a href="<%= install_url %>">Install guide</a>
    <%= link_to "Log in", new_user_session_path %>
  </footer>
</div>
```

- [ ] **Step 6: Put the sign-in card back** — the view as it was before the first landing:

```bash
git show 1a33e5b4^:app/views/users/sessions/new.html.erb > app/views/users/sessions/new.html.erb
git rm -q app/assets/images/landing/library.jpg
```

- [ ] **Step 7: Rewrite `app/assets/stylesheets/pages/landing.css`**

```css
/* The landing (second pass, 2026-10-16): the marketing page at `/` on the public demo's box -- a nav,
   the pitch beside a wall of twelve renders, how it works, four features with crops, a band on
   self-hosting, a closing line and a footer (docs/superpowers/specs/2026-10-16-landing-format-wall-
   design.md). Shared pieces are NOT restyled here: `.brand` comes from shell.css and `.btn` from
   components.css (design-system.md rule 3); where the landing needs them different it qualifies them
   inside its own containers. Tokens only. */
@layer pages {
  /* The anonymous layout branch defaults `main` to `.auth-main`, a 440px column for the card alone.
     The landing opts out with `content_for :container_class, "landing-main"`. A BARE class wins here
     because `pages` comes after `shell` in the layer order, as `.public-main` does (css_hygiene_test
     derives the variant from the view and checks it). */
  .landing-main { max-width: 1200px; padding-top: var(--space-5); padding-bottom: var(--space-8); }

  .landing { display: grid; gap: var(--space-8); }
  .landing h2, .landing h3, .landing p { margin: 0; }

  /* NAV. The rail's `.brand`, reused: the ≤1099px rail rules hide `.brand-name` and centre `.brand`,
     so this restores both, the one-line override the public header makes. */
  .landing-nav { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--space-4); }
  .landing-nav .brand { justify-content: flex-start; padding: 0; }
  .landing-nav .brand-name { display: inline; }
  .landing-nav-links { display: flex; gap: var(--space-5); font-size: 14px; }
  .landing-nav-links a, .landing-footer a { color: var(--fg-muted); }
  .landing-nav-links a:hover, .landing-footer a:hover { color: var(--fg); }

  /* HERO: the pitch, then the wall on a phone; side by side from 900px. `minmax(0, …)` and never a
     bare `fr`: a track's default minimum is its content's min-width, and a row of 256px images would
     hold it open past a phone's viewport (rule 11). */
  .landing-hero { display: grid; gap: var(--space-6); grid-template-columns: minmax(0, 1fr); align-items: center; }
  @media (min-width: 900px) { .landing-hero { grid-template-columns: minmax(0, 5fr) minmax(0, 6fr); gap: var(--space-7); } }
  .landing-title { font-size: 40px; line-height: 46px; font-weight: 600; letter-spacing: -0.02em; max-width: 16ch; margin-bottom: var(--space-4); }
  .landing .landing-lede { font-size: 17px; line-height: 26px; color: var(--fg-muted); max-width: 52ch; margin-bottom: var(--space-5); }
  .landing-actions { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-3); }
  .landing-actions form { margin: 0; }
  .landing .landing-hint { margin-top: var(--space-3); font-size: 13px; line-height: 18px; color: var(--fg-muted); }

  /* THE WALL: three across on a phone, four from 900px. Each tile is the app's own render, so it
     sits on the thumb stage, white in both themes because renders are opaque white PNGs (rule 5).
     The extension is mono because it is data, on a stage-coloured chip so it reads over any render. */
  .landing-wall-figure { margin: 0; }
  .landing-wall-figure figcaption { margin-top: var(--space-3); font-size: 13px; line-height: 18px; color: var(--fg-muted); }
  .landing-wall { list-style: none; margin: 0; padding: 0; display: grid; gap: var(--space-2); grid-template-columns: repeat(3, minmax(0, 1fr)); }
  @media (min-width: 900px) { .landing-wall { grid-template-columns: repeat(4, minmax(0, 1fr)); gap: var(--space-3); } }
  .landing-tile { position: relative; aspect-ratio: 1; overflow: hidden; border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--thumb-stage); }
  .landing-tile img { display: block; width: 100%; height: 100%; object-fit: contain; }
  .landing-tile-ext { position: absolute; left: 6px; bottom: 6px; padding: 0 4px; border-radius: var(--radius-control); background: var(--thumb-stage); color: var(--thumb-ink); font-family: var(--font-mono); font-size: 11px; line-height: 16px; }

  .landing .landing-section-title { font-size: 24px; line-height: 30px; font-weight: 600; letter-spacing: -0.01em; margin-bottom: var(--space-5); }

  /* HOW IT WORKS: three numbered steps, one row from 720px. */
  .landing-steps ol { list-style: none; margin: 0; padding: 0; counter-reset: step; display: grid; gap: var(--space-5); grid-template-columns: minmax(0, 1fr); }
  @media (min-width: 720px) { .landing-steps ol { grid-template-columns: repeat(3, minmax(0, 1fr)); } }
  .landing-steps li { counter-increment: step; padding-top: var(--space-4); border-top: 1px solid var(--line); }
  .landing-steps li::before { content: counter(step); display: block; margin-bottom: var(--space-2); font-family: var(--font-mono); font-size: 13px; color: var(--fg-muted); }
  .landing .landing-steps h3 { font-size: 17px; line-height: 24px; font-weight: 600; margin-bottom: var(--space-2); }
  .landing-steps p, .landing-feature-text p, .landing-own p, .landing-closing p { font-size: 15px; line-height: 23px; color: var(--fg-muted); }

  /* FEATURES: the text beside its crop from 900px, alternating sides; the crop under the text below.
     Counted inside `.landing-features`, so `:nth-child` sees features only. */
  .landing-features { display: grid; gap: var(--space-8); }
  .landing-feature { display: grid; gap: var(--space-5); grid-template-columns: minmax(0, 1fr); align-items: center; }
  @media (min-width: 900px) {
    .landing-feature { grid-template-columns: minmax(0, 2fr) minmax(0, 3fr); gap: var(--space-7); }
    .landing-feature:nth-child(even) { grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); }
    .landing-feature:nth-child(even) .landing-feature-text { order: 2; }
  }
  .landing .landing-feature h2 { font-size: 22px; line-height: 28px; font-weight: 600; margin-bottom: var(--space-3); }
  .landing-feature-shot { margin: 0; }
  .landing-feature-shot img { display: block; width: 100%; height: auto; border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface); }

  /* YOURS, ON YOUR BOX: four short cells in a panel, two across on a phone. */
  .landing-own { padding: var(--space-6); border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface); }
  .landing-own ul { list-style: none; margin: 0; padding: 0; display: grid; gap: var(--space-5); grid-template-columns: repeat(2, minmax(0, 1fr)); }
  @media (min-width: 900px) { .landing-own ul { grid-template-columns: repeat(4, minmax(0, 1fr)); } }
  .landing .landing-own h3 { font-size: 15px; line-height: 22px; font-weight: 600; margin-bottom: var(--space-1); }

  /* CLOSING AND FOOTER. */
  .landing-closing { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: var(--space-5); padding-top: var(--space-6); border-top: 1px solid var(--line); }
  .landing .landing-closing h2 { font-size: 22px; line-height: 28px; font-weight: 600; margin-bottom: var(--space-1); }
  .landing-footer { display: flex; flex-wrap: wrap; gap: var(--space-2) var(--space-5); font-size: 13px; color: var(--fg-muted); }

  @media (max-width: 899px) {
    .landing { gap: var(--space-7); }
    .landing-title { font-size: 30px; line-height: 36px; }
    .landing .landing-lede { font-size: 15px; line-height: 23px; }
  }
}
```

- [ ] **Step 8: Update the three tests that read the old landing.**
  - `test/integration/web/auth_pages_test.rb:129-130` — replace the comment and assertion with:

```ruby
      # The card carries the brand again (the landing's second pass, 2026-10-16, gave `/` its own page).
      assert_select ".auth-card .brand .brand-name", text: "Tinkerex"
```

  - `test/integration/web/demo_session_test.rb:143-146` (demo on, another account) — after
    `assert_response :success, "the landing, not Recent: nobody was signed in"` the two assertions become:

```ruby
      assert_select ".demo-banner", 0
      assert_select ".landing-hero", 1
      assert_select "form[action=?]", demo_session_path, { count: 0 }, "no demo button on the landing either"
```

  - `test/integration/web/demo_session_test.rb:175-178` (the refused click, demo on) — the last
    assertion `assert_select ".auth-card form[action=?]", user_session_path` becomes
    `assert_select ".landing-hero", 1`.

- [ ] **Step 9: Run the web tests and the guards this touches**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/landing_test.rb test/integration/web/auth_pages_test.rb test/integration/web/demo_session_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/architecture_invariants_test.rb test/no_emoji_test.rb`
Expected: 0 failures, 0 errors. Then `grep -rn "landing-brand\|landing-auth\|landing-shots\|landing-source" app test` → no output.

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb app/controllers/landings_controller.rb app/views/landings app/views/users/sessions/new.html.erb \
  app/assets/stylesheets/pages/landing.css app/assets/images/landing test/integration/web
printf '%s\n' "Signed out, / is the format-wall landing on the demo's box and the plain sign-in card elsewhere" "" \
  "A wall of twelve of the app's own renders beside the pitch, how it works, four features with" \
  "crops, and Try the demo as the one accent (Install when the demo account is missing)." "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

---

## Task 6: The browser tests

**Files:**
- Rewrite: `test/system/landing_test.rb`
- Modify: `test/system/accent_spend_test.rb` (one new test)
- Modify: `test/system/shell_test.rb:181-185`

- [ ] **Step 1: Rewrite `test/system/landing_test.rb`**

```ruby
require "application_system_test_case"

# THE LANDING IN A BROWSER (second pass, 2026-10-16). What a request test cannot see: that
# `landing-main` beats the layout's 440px auth column (a computed width), that the wall stands beside
# the pitch on a desktop and under it on a phone, that every tile actually LOADED (an <img> whose
# bytes do not decode is a broken box a request test passes over), and that nothing scrolls sideways
# at 375px (design-system.md rule 11). The viewport is set through CDP: headless Chrome refuses a
# window narrower than 500px.
class LandingSystemTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    User.create!(email: "demo@example.com", password: SecureRandom.base58(32), confirmed_at: Time.current, handle: "demo")
  end

  teardown do
    @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def rect(selector)
    page.evaluate_script("(r => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }))" \
                         "(document.querySelector(#{selector.to_json}).getBoundingClientRect())")
  end

  test "the wall stands beside the pitch at desktop width, every tile loads, and a phone stacks it without sideways scroll" do
    visit "/"
    assert_selector ".landing-hero h1"
    assert_selector ".landing-wall img", count: Tinkerex::Landing::TILES.size

    width = rect("main#main")["width"]
    assert_operator width, :>, 900, "main is #{width}px wide: the landing is still inside the 440px auth column"
    assert_operator rect(".landing-pitch")["right"], :<=, rect(".landing-wall")["left"],
                    "the wall should stand right of the pitch at desktop width"

    # LOADED, NOT MERELY PRESENT: a tile whose bytes do not decode has naturalWidth 0.
    widths = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const imgs = [...document.querySelectorAll('.landing-wall img')];
      Promise.all(imgs.map(i => i.complete ? null : new Promise(r => { i.onload = i.onerror = r })))
        .then(() => done(imgs.map(i => i.naturalWidth)));
    JS
    assert widths.all?(&:positive?), "a wall tile did not load: naturalWidths #{widths.inspect}"

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit "/"
      assert_selector ".landing-hero h1"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
             "the landing scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      assert_operator rect(".landing-wall")["top"], :>=, rect(".landing-pitch")["bottom"],
                      "the wall should stack under the pitch on a phone"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end
end
```

- [ ] **Step 2: Add the landing to the accent guard** — append inside `class AccentSpendTest`,
  above `private`:

```ruby
  # THE LANDING (2026-10-16): signed out on a demo deployment, its one action is Try the demo
  # (design-system.md rule 15). Its own test because every route above is signed in. The setup's
  # account doubles as the demo account -- the only account, so on share and s3 no other library
  # sharer closes the demo's door and the expectation is the same on every leg.
  test "the landing spends the accent on Try the demo" do
    prior = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV["DEMO_ACCOUNT_EMAIL"] = @user.email
    Capybara.reset_sessions!
    visit "/"
    assert_selector ".landing-hero h1"
    assert_equal [ "Try the demo" ], accent_controls
  ensure
    prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
  end
```

- [ ] **Step 3: The sign-out toast waits for the card** — in `test/system/shell_test.rb`, replace
  the two comment lines beginning `# Since the landing (2026-10-14)` and the line
  `assert_selector ".landing-hero"` with:

```ruby
    # Devise lands a sign-out on root_path, which, with demo mode off as it is here, a visitor sees as
    # the plain sign-in card (landing_test.rb).
    find("aside.rail button", text: "Sign out").click
    assert_current_path root_path
    assert_selector ".auth-card form[action='#{user_session_path}']"
```

  (the `find(...)` and `assert_current_path` lines already exist between them; keep exactly one of each).

- [ ] **Step 4: Run the system tests**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/landing_test.rb test/system/accent_spend_test.rb test/system/shell_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Look at the page** (`superpowers:verification-before-completion` asks for eyes, and
  §14e says only a browser knows): boot a dev server with `DEMO_ACCOUNT_EMAIL` set and the demo
  account created (memory: dev-server-for-screenshots recipe), open `/` in the built-in browser at
  1440, 1024 and 375 wide, light and dark theme cookie, and read: no console errors, nothing
  overlapping, the wall's labels legible over every tile, the features alternating sides.

- [ ] **Step 6: Commit**

```bash
git add test/system
printf '%s\n' "Browser tests read the landing's layout, its tiles' load and its one accent" "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

---

## Task 7: The rules, and the follow-up

**Files:**
- Modify: `docs/invariants/design-system.md` (rule 15)

- [ ] **Step 1: Replace rule 15** (the paragraph under `## The front door`) with:

```markdown
15. **Signed out, `/` has two answers and demo mode picks; signed in it is Recent.** On the public
    demo's box (`Tinkerex::Landing.enabled?`, which is `Tinkerex::Demo.enabled?`) it is the marketing
    landing; anywhere else it is the plain sign-in card, because a self-hosted box has nobody to pitch
    to and the landing's one action IS the demo. `config/routes.rb` declares three roots in this
    order: the landing (`landing_root`, a request-time constraint on demo mode), the card
    (`unauthenticated_root`), then `root` — any other order and a visitor meets the wrong door
    (`test/integration/web/landing_test.rb`). `LandingsController` stands on `ActionController::Base`,
    never on `ApplicationController` with a skip (`architecture_invariants_test.rb`'s default-deny),
    and outside `Public::` because its demo button's CSRF token writes the session. The accent is Try
    the demo while `Tinkerex::Demo.available?`, else Install — exactly once either way (rule 13;
    `accent_spend_test.rb`). `/users/sign_in` is the plain card everywhere. **The wall's twelve tiles
    are the app's own renders** of twelve files of the owner's `catan` project, which `db/seeds/demo`
    holds whole (the seed's 70 MB budget is that decision, `demo_reset_test.rb`), written by `bin/rails landing:wall`
    (`Tinkerex::Landing`, which refuses rather than skips); **the four feature crops are the app
    photographed** by `script/landing/capture_crops.rb`, the demo banner removed and nothing else
    touched. Retake both when the renderers or the pages move; never draw or edit them.
    `test/system/landing_test.rb` reads the computed width, every tile's load and the 375px overflow,
    which a request test cannot see.
```

- [ ] **Step 2: Run the docs guard**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb`
Expected: 0 failures (the §14m stub still says fifteen rules).

- [ ] **Step 3: Commit**

```bash
git add docs/invariants/design-system.md
printf '%s\n' "design-system.md rule 15 describes the front door's three answers" "" \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" | git commit -q -F -
```

- [ ] **Step 4: File the Tools follow-up** (the fourth feature row is untrue on tinkerex.com until it
  lands; deploying OVH stays the owner's call):

```bash
bin/log open "Boot the addons accessory (and boxes sidecar) on OVH so the demo's Tools gallery matches the landing's box-generator row"
```

  Exit 3 means the Kaneo was unreachable and the write was spooled; file it with `bin/log status`
  later, as §13 says.

---

## Task 8: Verify, mutation-check, finish

- [ ] **Step 1: Full gates**

Run: `bin/ci` (with `TINKEREX_SYNC_DIR=../tinkerex-sync` if run from a worktree).
Expected: every gate green; the three backend legs report identical RUN counts (assertion and skip
deltas of the usual shape are normal — memory: backend-legs-structural-assertion-deltas).

- [ ] **Step 2: Mutation-check each guard this work added** (§15). Break, run the named test, see it
  RED, restore, `rm -rf tmp/cache/bootsnap*`, see it green:
  1. `config/routes.rb`: `Tinkerex::Landing.enabled?` → `!Tinkerex::Landing.enabled?` — `landing_test.rb` red.
  2. Move the landing's `unauthenticated` block below `root to: "home#index"` — `landing_test.rb` red.
  3. Give the closing "Try the demo" `class: "btn primary"` — `landing_test.rb` and `accent_spend_test.rb` red.
  4. `: > app/assets/images/landing/wall/hex-tiles-lbrn2.png` (zero bytes; `git checkout` it back) — `test/system/landing_test.rb` red on the load check.
  5. In `lib/tinkerex/landing.rb`, delete the `raise Error, "no preview renderer claims …"` line — `landing_wall_test.rb` red.
  6. In `render_wall`, write each tile inside the `map` that renders it — "a refused tile writes nothing" red.

- [ ] **Step 3: Finish** — invoke `/finish-branch` (commit, push, PR whose body states what was
  verified and what was not: no deployment ran; the GitHub links 404 until the repository is public;
  the Tools row waits on the OVH follow-up; the seed now carries the owner's 61 MB `catan` project,
  so the image grows by that much and the nightly reset writes it), then `bin/log arc --from-pr <n>`. Merging and the OVH
  deploy (`kamal deploy -d ovh --skip-push --hosts 15.204.216.249` after `kamal build push`) wait
  for the owner's word.
```
