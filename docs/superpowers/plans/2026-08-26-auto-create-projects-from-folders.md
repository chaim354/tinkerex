# Auto-create a project from a folder under `Projects/` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live folder directly under the library's `Projects/` that no project claims becomes a `Maker::Project`.

**Architecture:** A new `Maker::ProjectDiscovery` service sweeps `nodes` — the catalog all three backends populate — and writes `maker_projects` rows. It never touches the `FileLayer` port, so it is identical on all three backends and testable with no library on disk. `Maker::ProjectDiscoveryJob` mirrors `Maker::ModelIntakeJob`: a per-user recurring sweep gated off scannable backends, where `Library::ScanJob` sequences it inline instead. Discovery runs **strictly after the reconcile and strictly before the filing sweep** — both orderings change the answer, not the timing.

**Tech Stack:** Rails 8, Minitest, Solid Queue (recurring + `limits_concurrency`), SQLite in test.

**Spec:** `docs/superpowers/specs/2026-08-26-auto-create-projects-from-folders-design.md`

**No migration.** Archiving is the dismissal: an archived project keeps its `folder_node_id`, and the claim lookup is unscoped.

---

## File Structure

**Create**

| File | Responsibility |
|---|---|
| `app/services/maker/project_discovery.rb` | The rule. Pure DB: which folders are adoptable, and minting a row per folder. No port calls. |
| `app/jobs/maker/project_discovery_job.rb` | The scheduled half: fan-out gate, concurrency limit, operator logging, and the chunk_remote follow-on chain. |
| `test/services/maker/project_discovery_test.rb` | The rule's tests. |
| `test/jobs/maker/project_discovery_job_test.rb` | Gate arms, the chain, and the logging. |
| `docs/invariants/project-intake.md` | §14f's area file — the existing project-intake invariants plus discovery's. |

**Modify**

| File | Change |
|---|---|
| `app/services/maker/project_folders.rb` | Add `ROOT = "Projects"`. |
| `app/models/maker/project.rb` | Add `.slugify` / `.available_slug`; `#ensure_slug` reuses `.slugify`; `#ensure_library_folder!` reads `ROOT`. |
| `app/services/maker/project_intake.rb` | `#place` resolves its destination under the project's **folder node**, not a path rebuilt from the slug. |
| `app/jobs/library/scan_job.rb` | `#discover_projects`, before `#intake_project_folders`. |
| `config/recurring.yml` | `project_discovery`, every 15 minutes. |
| `lib/tasks/projects.rake` | `projects:discover`. |
| `test/services/maker/project_folders_test.rb` | Drift guard on the `"Projects"` literal. |
| `test/models/maker/project_test.rb` | Slug helper tests. |
| `test/services/maker/project_intake_test.rb` | The folder-node destination fix. |
| `test/jobs/library/scan_job_test.rb` | `DiscoveryOrderTest`. |
| `test/docs_hygiene_test.rb` | Ratchet `MAX_LINES` down after the §14f move. |
| `CLAUDE.md` | §14f becomes a stub. |
| `docs/STATUS.md` | The arc entry — same branch, same PR (§15). |

---

## Task 1: `Maker::ProjectFolders::ROOT`

The literal `"Projects"` is spelled out in two files today and discovery would be the third. Three copies of a string that must agree is the drift this module's own header already records for ext⇒folder tables.

**Files:**
- Modify: `app/services/maker/project_folders.rb`
- Modify: `app/models/maker/project.rb:82`
- Modify: `app/services/maker/project_intake.rb:715`
- Test: `test/services/maker/project_folders_test.rb`

- [ ] **Step 1: Write the failing guard**

Append inside the existing test class in `test/services/maker/project_folders_test.rb`:

```ruby
  # THE LITERAL MUST NOT REAPPEAR. ROOT exists because "Projects" was spelled out in two files and
  # a third was about to add it. A constant nothing enforces is a convention, and this repo's
  # recorded drift (FilesHelper::EXT_FAMILIES vs ROLE_BY_EXT — two lists that disagreed about .svg
  # for months) is what a convention buys you.
  #
  # Mutation-check: put `"Projects"` back into any file below and this goes RED.
  test "no maker file spells the Projects root as a bare literal" do
    files = %w[
      app/models/maker/project.rb
      app/services/maker/project_intake.rb
      app/services/maker/project_discovery.rb
    ].map { |f| Rails.root.join(f) }.select(&:exist?)

    # ASSERT THE SCANNED SET FIRST (§14e). Two architecture guards in this repo went on passing
    # over an empty glob once the directory they scanned moved away; a path-keyed guard can be
    # silently retired by a rename.
    refute_empty files, "none of the maker files this guards exist — did they move?"

    offenders = files.select { |f| f.read.include?('"Projects"') }
                     .map { |f| f.relative_path_from(Rails.root).to_s }

    assert_empty offenders, "spell it Maker::ProjectFolders::ROOT, not a bare \"Projects\""
  end
```

- [ ] **Step 2: Run it and verify it fails**

```bash
bin/rails test test/services/maker/project_folders_test.rb
```

Expected: FAIL — offenders lists `app/models/maker/project.rb` and `app/services/maker/project_intake.rb`.

- [ ] **Step 3: Add the constant**

In `app/services/maker/project_folders.rb`, immediately after `module_function`:

```ruby
    # The library folder every project's own folder lives under: `Projects/<slug>/`.
    #
    # ONE DEFINITION, THREE READERS — Maker::Project#ensure_library_folder!,
    # Maker::ProjectIntake#place and Maker::ProjectDiscovery. It was a bare literal in the first two
    # and the third was about to add a copy. Guarded by project_folders_test.rb, which fails if the
    # literal reappears in any of them.
    ROOT = "Projects".freeze
```

- [ ] **Step 4: Update both readers**

`app/models/maker/project.rb` — in `#ensure_library_folder!`:

```ruby
      folder = Maker::LibraryFolder.ensure_path!(acting_user, [ Maker::ProjectFolders::ROOT, slug ])
```

`app/services/maker/project_intake.rb` — in `#place`:

```ruby
      target = Maker::LibraryFolder.ensure_path!(@user,
                                                 [ Maker::ProjectFolders::ROOT, @project.slug, dest ])
```

(Task 3 replaces this line entirely. It is updated here so the guard passes and the suite stays green between commits.)

- [ ] **Step 5: Run the guard and the project suites**

```bash
bin/rails test test/services/maker/project_folders_test.rb test/services/maker/project_intake_test.rb test/models/maker/project_test.rb
```

Expected: PASS, all three.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/project_folders.rb app/models/maker/project.rb app/services/maker/project_intake.rb test/services/maker/project_folders_test.rb
git commit -m "Maker::ProjectFolders::ROOT — one definition of the Projects folder name"
```

---

## Task 2: A slug an unattended run cannot fail on

`Maker::Project#ensure_slug` deliberately does **not** de-duplicate. `Maker::Model#ensure_slug`'s own comment says why: *"Project fails validation on collision; import can't afford that."* A sweep can't afford it either — nobody is there to read the error.

**Files:**
- Modify: `app/models/maker/project.rb`
- Test: `test/models/maker/project_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside the existing test class in `test/models/maker/project_test.rb`:

```ruby
  test "slugify normalizes a folder name" do
    assert_equal "desk-lamp", Maker::Project.slugify("Desk Lamp")
    assert_equal "desk-lamp", Maker::Project.slugify("  Desk--Lamp!  ")
    assert_equal "", Maker::Project.slugify("プロジェクト")
  end

  test "available_slug de-dups against the user's existing projects" do
    @user.maker_projects.create!(name: "Desk Lamp")

    assert_equal "desk-lamp-2", Maker::Project.available_slug(@user, from: "Desk Lamp")
  end

  # ANY PURELY NON-LATIN NAME REDUCES TO "" — slugify keeps only [a-z0-9] — and
  # `validates :slug, presence: true` would then raise inside a recurring job. Not exotic:
  # プロジェクト, Проект, 模型.
  test "available_slug falls back to project for a name with no latin characters" do
    assert_equal "project", Maker::Project.available_slug(@user, from: "プロジェクト")
  end

  # THE SLUG MUST SURVIVE THE CALLBACK. #ensure_slug re-normalizes `slug.presence || name`, so a
  # de-duped slug handed in explicitly has to normalize to itself — otherwise the -2 is stripped
  # back off on save and the create raises anyway.
  test "an explicitly supplied de-duped slug is stable through ensure_slug" do
    @user.maker_projects.create!(name: "Desk Lamp")
    slug = Maker::Project.available_slug(@user, from: "Desk Lamp")

    project = @user.maker_projects.create!(name: "Desk Lamp", slug:)

    assert_equal "desk-lamp-2", project.slug
  end

  # THE WEB FORM'S BEHAVIOUR IS DELIBERATELY UNCHANGED. A human typing a duplicate name SHOULD be
  # told; only the sweep gets the import treatment. This is the guard that Task 2's refactor did
  # not quietly turn #ensure_slug into a de-duper.
  test "a duplicate name still fails validation when no slug is supplied" do
    @user.maker_projects.create!(name: "Desk Lamp")

    duplicate = @user.maker_projects.new(name: "Desk Lamp")

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:slug], "has already been taken"
  end
```

If `test/models/maker/project_test.rb` has no `@user` in `setup`, add one:

```ruby
    setup do
      @user = User.create!(email: "pt-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end
```

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/models/maker/project_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'slugify' for Maker::Project`.

- [ ] **Step 3: Implement**

In `app/models/maker/project.rb`, add these two class methods above the `private` keyword:

```ruby
    # THE ONE NORMALIZATION. Extracted from #ensure_slug so Maker::ProjectDiscovery can reuse it
    # without a second copy of the regex.
    def self.slugify(str)
      str.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    # A SLUG AN UNATTENDED RUN CANNOT FAIL ON — the treatment Maker::Model#ensure_slug already gives
    # import, for the reason its own comment states: "Project fails validation on collision; import
    # can't afford that." A sweep can't afford it either, because nobody is there to read the error.
    #
    # TWO REACHABLE FAILURES, both of which raise inside a recurring job:
    #   * COLLISION — `Projects/desk-lamp` (a project's own folder) beside `Projects/Desk Lamp`
    #     (one the user made by hand). Both slugify to `desk-lamp`.
    #   * BLANK — slugify keeps only [a-z0-9], so ANY purely non-Latin name reduces to "":
    #     プロジェクト, Проект, 模型. `validates :slug, presence: true` then raises.
    #
    # #ensure_slug IS DELIBERATELY LEFT ALONE. A human typing a duplicate name into the web form
    # SHOULD be told; only the sweep gets the import treatment.
    def self.available_slug(user, from:)
      base = slugify(from)
      base = "project" if base.blank?
      candidate = base
      n = 2
      while user.maker_projects.exists?(slug: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      candidate
    end
```

Replace the private `#ensure_slug` body so the regex lives in one place:

```ruby
    def ensure_slug
      source = slug.presence || name
      return if source.blank?
      self.slug = self.class.slugify(source)
    end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/models/maker/project_test.rb
```

Expected: PASS.

- [ ] **Step 5: Mutation-check the last guard**

Temporarily change `#ensure_slug` to `self.slug = self.class.available_slug(user, from: source)` and re-run.

Expected: the "a duplicate name still fails validation" test goes **RED**. Restore `#ensure_slug` and confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/models/maker/project.rb test/models/maker/project_test.rb
git commit -m "Maker::Project.slugify + .available_slug — a slug a sweep cannot fail on"
```

---

## Task 3: `#place` files under the project's folder node, not a rebuilt path

**This is a bug fix, not a refactor.** `Maker::ProjectIntake#place` builds its destination as `[ROOT, @project.slug, dest]` — a path rebuilt from the **slug** — while `Maker::ProjectIntake.destination_for` resolves the same folder under the project's actual `folder_node_id`. They agree today only because `#ensure_library_folder!` always mints `Projects/<slug>`.

Discovery breaks that wholesale: a project discovered from `Projects/Desk Lamp` has slug `desk-lamp`, so `#place` would mint a **second** `Projects/desk-lamp/` tree and move the user's file into it, out of the folder they made. §14f already requires that prediction and behaviour cannot disagree.

**Files:**
- Modify: `app/services/maker/project_intake.rb`
- Test: `test/services/maker/project_intake_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside the existing `ProjectIntakeTest` class in `test/services/maker/project_intake_test.rb`. It uses that file's own `dir` / `file` helpers, which write real bytes under `@root` and stamp `storage_path` — required, because this suite runs against a real share library and §14a records that a `nodes.create!` fixture with a NULL `storage_path` cannot exist on share/s3.

```ruby
  # THE DESTINATION IS RESOLVED UNDER THE PROJECT'S FOLDER NODE, NEVER A PATH REBUILT FROM ITS SLUG.
  #
  # Reachable two ways, and Maker::ProjectDiscovery makes the second one the MAINLINE case:
  #   * rename a project's slug after its folder was minted — folder_node_id keeps pointing at the
  #     old `Projects/<old-slug>`;
  #   * adopt a folder whose NAME is not its slug — `Projects/Desk Lamp` with slug `desk-lamp`.
  #
  # Rebuilding the path mints a SECOND tree and moves the user's file into it, leaving the folder
  # the user made looking empty while the project still points at it. Nothing errors and nothing
  # logs — this repo's dominant failure shape.
  #
  # A SECOND PROJECT, not the fixture's @project, precisely because setup's
  # `ensure_library_folder!` gave that one a folder that DOES match its slug — which is the only
  # arrangement the old code could handle, and so the only one that could not catch this.
  test "a file is filed under the project's own folder node even when it is not named after the slug" do
    folder = dir("Desk Lamp", parent: nil)
    other  = @user.maker_projects.create!(name: "Bench Rig")
    other.update_column(:folder_node_id, folder.node_id)
    panel = file("panel.svg", parent: folder.node_id)

    Maker::ProjectIntake.for_project(user: @user, project: other)

    design = @user.nodes.present.find_by(parent_node_id: folder.node_id, name: "design",
                                         kind: "dir")
    refute_nil design, "the category folder must be created UNDER the project's own folder node"
    assert_equal design.node_id, panel.reload.parent_node_id
    assert_nil @user.nodes.present.find_by(name: "bench-rig", kind: "dir"),
               "no second Projects/<slug> tree may be minted"
  end
```

- [ ] **Step 2: Run and verify it fails**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: FAIL — `design` is nil under `d-desk-lamp`, and a `desk-lamp` dir node exists.

- [ ] **Step 3: Memoize the folder lookup**

In `app/services/maker/project_intake.rb`, replace the private `#live_folder` with:

```ruby
    # MEMOIZED because #place now reads it once per file. Without the memo a 200-file inbox pays 200
    # identical lookups; #call already returns early when it is nil, so the `||=` never re-queries a
    # miss in a live run.
    def live_folder
      return nil if @project.folder_node_id.blank?
      @live_folder ||= @user.nodes.present.find_by(node_id: @project.folder_node_id, kind: "dir")
    end
```

- [ ] **Step 4: Resolve the destination under that node**

In `#place`, replace the `target = ...` line:

```ruby
      # UNDER THE PROJECT'S OWN FOLDER NODE, NEVER A PATH REBUILT FROM THE SLUG. The two agree only
      # while #ensure_library_folder! is the sole writer of folder_node_id and the slug has never
      # changed — and Maker::ProjectDiscovery adopts folders whose NAME is not their slug as the
      # mainline case. Rebuilding the path mints a second `Projects/<slug>/` tree and moves the
      # user's file into it, silently. `create_child!` is ensure_path!'s single-segment sibling and
      # is find-or-create, so this stays idempotent.
      #
      # THIS IS ALSO WHAT MAKES #place AGREE WITH .destination_for, which has always resolved the
      # category folder under `parent_node_id` (§14f: prediction and behaviour cannot disagree).
      target = Maker::LibraryFolder.create_child!(@user, parent_node_id: live_folder.node_id,
                                                  name: dest)
```

- [ ] **Step 5: Run and verify it passes**

```bash
bin/rails test test/services/maker/project_intake_test.rb
```

Expected: PASS, including every pre-existing test in the file.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/project_intake.rb test/services/maker/project_intake_test.rb
git commit -m "ProjectIntake#place files under the project's folder node, not a slug-rebuilt path"
```

---

## Task 4: `Maker::ProjectDiscovery` — the happy path

**Files:**
- Create: `app/services/maker/project_discovery.rb`
- Test: `test/services/maker/project_discovery_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/services/maker/project_discovery_test.rb`:

```ruby
require "test_helper"

module Maker
  class ProjectDiscoveryTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pd-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @root = dir("d-projects", "Projects", nil)
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    test "an unclaimed folder becomes a project named verbatim and pointed at that folder" do
      dir("d-lamp", "Desk Lamp", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "Desk Lamp", project.name
      assert_equal "desk-lamp", project.slug
      assert_equal "d-lamp", project.folder_node_id
    end

    test "the run reports its own delta and the candidate count" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      dir("d-rack", "Rack", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 2, run.created
      assert_equal 2, run.candidates
      assert_equal :ok, run.status
    end

    # STEADY STATE REPORTS 0, not the number of projects the user has.
    test "a second sweep creates nothing" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      Maker::ProjectDiscovery.for_user(user: @user)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 1, @user.maker_projects.count
    end

    # TWO FOLDERS THAT SLUGIFY THE SAME BOTH ADOPT. `Projects/desk-lamp` (a project's own folder)
    # beside `Projects/Desk Lamp` (one made by hand) is the reachable case.
    test "colliding names both adopt, the second de-duped" do
      dir("d-a", "Desk Lamp", "d-projects")
      dir("d-b", "desk-lamp", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal %w[desk-lamp desk-lamp-2], @user.maker_projects.order(:slug).pluck(:slug)
    end

    test "a name with no latin characters adopts as project" do
      dir("d-jp", "プロジェクト", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "プロジェクト", project.name
      assert_equal "project", project.slug
    end
  end
end
```

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/services/maker/project_discovery_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Maker::ProjectDiscovery`.

- [ ] **Step 3: Implement**

Create `app/services/maker/project_discovery.rb`:

```ruby
module Maker
  # A folder directly under the library's `Projects/` that no project claims becomes a project.
  #
  # WHY A SWEEP RATHER THAN A HOOK PER DOOR — the same argument Maker::ProjectIntake and
  # Maker::ModelIntake make. A folder can reach `Projects/` several ways
  # (LibraryBrowseController#create_folder, Library::Reconciler observing one someone made in
  # Finder, a device push landing on the sync server, Maker::MoveNode) and there is no funnel.
  # Hooking each is N sites that must agree, and an N+1th silently skips the rule. This reads
  # `nodes`, the catalog ALL THREE BACKENDS populate, so it covers every door and any future one.
  #
  # IT NEVER TOUCHES THE PORT. It writes maker_projects rows and nothing else — no mkdir, no move,
  # no bytes — which is what makes it identical on all three backends and testable without a
  # library on disk.
  #
  # Rules and reasoning: docs/invariants/project-intake.md.
  class ProjectDiscovery
    # What one run did.
    #
    # `created` IS THIS RUN'S DELTA, not the total, so a steady-state sweep reports 0 rather than
    # the number of projects the user has. `candidates` is how many adoptable folders survived the
    # filters, which is what makes :capped legible ("created 50 of 63") and is the only reason it
    # exists — there is deliberately NO per-reason skips breakdown, because the dominant "skip" is
    # ALREADY CLAIMED, which is the steady state and would print a number every tick meaning
    # nothing happened.
    RunResult = Data.define(:created, :candidates, :status, :cap)

    # The ceiling on projects created in one run. ABSOLUTE, NOT A PERCENTAGE, for the reason
    # Maker::ProjectIntake::MAX_MOVES gives at length: the intended first run adopts 100% of what is
    # there, so a percentage would be guarding against success.
    #
    # ONE CAP, NOT TWO. Maker::ProjectIntake carries EAGER_MAX_MOVES beside MAX_MOVES because it has
    # an entry point inside a browser request. Nothing here does — the web doors' eager nudge calls
    # Maker::ProjectIntake.for_node directly and never routes through a job. WHOEVER ADDS A NUDGE
    # OWES THE SECOND CAP.
    MAX_PROJECTS = 50

    # A BAD OVERRIDE FALLS BACK; IT DOES NOT CRASH THE JOB. `Integer("-5")` SUCCEEDS, so the rescue
    # below never sees a negative — and a negative reaches `first(-5)`, which raises
    # `ArgumentError: negative array size` deep inside a recurring job, long after the typo. Zero is
    # refused for the same reason: it discovers nothing, forever, silently.
    def self.max_projects
      value = Integer(ENV.fetch("PROJECT_DISCOVERY_MAX", MAX_PROJECTS))
      value.positive? ? value : MAX_PROJECTS
    rescue ArgumentError, TypeError
      MAX_PROJECTS
    end

    def self.for_user(user:, cap: nil)
      cap ||= max_projects
      root = projects_root(user)
      return RunResult.new(created: 0, candidates: 0, status: :no_projects_folder, cap:) unless root

      candidates = adoptable(user, root)
      capped = candidates.size > cap

      created = 0
      candidates.first(cap).each do |node_id, name|
        user.maker_projects.create!(
          name:,
          # NOT #ensure_slug's derivation. A collision or a blank raises RecordInvalid inside a
          # recurring job, where nobody is there to read it — see Maker::Project.available_slug.
          slug: Maker::Project.available_slug(user, from: name),
          # THE FOLDER ALREADY EXISTS; this claims it. Calling #ensure_library_folder! would mint
          # `Projects/<slug>` as a side effect of merely looking — Projects::AttachmentsController
          # #relocate's recorded bug, at library-sweep scale.
          folder_node_id: node_id
        )
        created += 1
      end

      RunResult.new(created:, candidates: candidates.size, status: capped ? :capped : :ok, cap:)
    end

    # NEVER MINTS `Projects/`. Calling Maker::LibraryFolder.ensure_path! here would create it on
    # every library that has never had one, as a side effect of merely LOOKING. A user with no
    # Projects/ folder is simply not swept.
    #
    # `parent_node_id: nil` IS the library root — the representation Library::Reconciler and
    # Maker::LibraryTree both use.
    def self.projects_root(user)
      user.nodes.present.find_by(parent_node_id: nil, name: Maker::ProjectFolders::ROOT,
                                 kind: "dir")
    end
    private_class_method :projects_root

    # [[node_id, name], ...] in DETERMINISTIC order, so a capped run is reproducible and the next
    # run continues where this one stopped instead of re-rolling the dice.
    def self.adoptable(user, root)
      # UNSCOPED, AND THAT IS THE ENTIRE DISMISSAL MECHANISM. Archiving a project leaves
      # folder_node_id intact, so an archived project still claims its folder and this passes over
      # it. Filtering archived rows out HERE is exactly how a dismissed thing comes back —
      # docs/invariants/model-intake.md records the identical mistake for the `catalogued` scope.
      # THE ROW IS THE MEMORY.
      claimed = user.maker_projects.where.not(folder_node_id: nil).pluck(:folder_node_id).to_set

      # DIRECT CHILDREN ONLY. `Projects/desk-lamp/models/` is a category subfolder
      # Maker::ProjectFolders created, and adopting it would mint a project named "models" inside a
      # project. A project folder is `Projects/<name>` and nothing deeper.
      #
      # DOT-FOLDERS ARE SKIPPED. Library::OsClutter already stops `.DS_Store` and friends from ever
      # becoming nodes, but `.git` is THE ONE SKIP THAT KEEPS ITS ENTRY (§14b — the marker is the
      # evidence a directory is a working tree, which Maker::AttachToProject's :in_working_tree asks
      # the database for). Without this rule a repo checked out at the Projects/ root becomes a
      # project literally titled ".git".
      user.nodes.present
          .where(parent_node_id: root.node_id, kind: "dir")
          .order(:node_id)
          .pluck(:node_id, :name)
          .reject { |node_id, name| claimed.include?(node_id) || name.to_s.start_with?(".") }
    end
    private_class_method :adoptable
  end
end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/services/maker/project_discovery_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Mutation-check the slug guards**

In `for_user`, delete the `slug:` argument entirely so `create!` falls back to `#ensure_slug`'s derivation, and re-run.

Expected: **both** "colliding names both adopt, the second de-duped" and "a name with no latin characters adopts as project" go **RED** with `ActiveRecord::RecordInvalid` — the two failures `Maker::Project.available_slug` exists to prevent, each raising from inside what would be a recurring job. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/project_discovery.rb test/services/maker/project_discovery_test.rb
git commit -m "Maker::ProjectDiscovery — adopt an unclaimed folder under Projects/"
```

---

## Task 5: The skip rules

**Files:**
- Test: `test/services/maker/project_discovery_test.rb`

No implementation changes — Task 4's code already satisfies these. These tests exist to **pin** each rule so a later edit cannot quietly drop one, and each is mutation-checked in Step 3.

- [ ] **Step 1: Write the tests**

Append inside `ProjectDiscoveryTest`:

```ruby
    # ARCHIVING IS THE DISMISSAL, AND THIS IS THE TEST THAT MAKES IT ONE. An archived project keeps
    # its folder_node_id, so the unscoped claim lookup passes over its folder forever.
    test "an archived project still claims its folder" do
      folder = dir("d-lamp", "Desk Lamp", "d-projects")
      project = @user.maker_projects.create!(name: "Desk Lamp")
      project.update_column(:folder_node_id, folder.node_id)
      project.archive!

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 1, @user.maker_projects.count
    end

    # `.git` KEEPS ITS NODE (§14b) — it is the evidence a directory is a working tree — so without
    # the dot rule a repo checked out at the Projects/ root becomes a project titled ".git".
    test "dot-folders are skipped" do
      dir("d-git", ".git", "d-projects")
      dir("d-hidden", ".scratch", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 0, run.candidates
    end

    test "a folder deeper than a direct child is not adopted" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      dir("d-models", "models", lamp.node_id)

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal [ "d-lamp" ], @user.maker_projects.pluck(:folder_node_id)
    end

    test "a file directly under Projects is not adopted" do
      file("f-stray", "stray.stl", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
    end

    test "a tombstoned folder is not adopted" do
      dir("d-gone", "Gone", "d-projects").update!(deleted: true)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
    end

    # NEVER MINTS `Projects/`. A user with no Projects folder is not swept — creating one as a side
    # effect of merely looking is Projects::AttachmentsController#relocate's recorded bug at
    # library-sweep scale.
    test "a library with no Projects folder creates nothing and mints nothing" do
      @user.nodes.destroy_all
      dir("d-other", "3D Models", nil)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal :no_projects_folder, run.status
      assert_equal 0, run.created
      assert_nil @user.nodes.present.find_by(name: "Projects", kind: "dir")
    end

    # THE PORT IS NEVER TOUCHED — no mkdir, no move, no bytes. That is what makes this sweep
    # identical on all three backends.
    test "the sweep creates no library nodes at all" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      before = @user.nodes.count

      # ASSERT THE SCANNED SET IS NON-EMPTY FIRST (§14e): "no nodes were created" is satisfied just
      # as happily by a sweep that found nothing to do, and that arm proves nothing.
      run = Maker::ProjectDiscovery.for_user(user: @user)
      assert_equal 1, run.created, "precondition: the sweep must actually have adopted something"

      assert_equal before, @user.nodes.count
    end
```

- [ ] **Step 2: Run and verify they pass**

```bash
bin/rails test test/services/maker/project_discovery_test.rb
```

Expected: PASS, 12 tests.

- [ ] **Step 3: Mutation-check each rule**

Make each change, run the file, confirm the named test goes **RED**, then restore:

| Mutation in `app/services/maker/project_discovery.rb` | Test that must go RED |
|---|---|
| `user.maker_projects.where(archived_at: nil).where.not(folder_node_id: nil)` | "an archived project still claims its folder" |
| delete `\|\| name.to_s.start_with?(".")` | "dot-folders are skipped" |
| `.where(kind: "dir")` → drop the `parent_node_id` clause | "a folder deeper than a direct child is not adopted" |
| `.where(parent_node_id: root.node_id)` → drop `kind: "dir"` | "a file directly under Projects is not adopted" |
| `user.nodes.where(...)` (drop `.present`) | "a tombstoned folder is not adopted" |
| `projects_root` → `Maker::LibraryFolder.ensure_path!(user, [ Maker::ProjectFolders::ROOT ])` | "a library with no Projects folder creates nothing and mints nothing" |

- [ ] **Step 4: Commit**

```bash
git add test/services/maker/project_discovery_test.rb
git commit -m "Pin ProjectDiscovery's skip rules — archived claims, dot-folders, depth, no minting"
```

---

## Task 6: The cap

**Files:**
- Test: `test/services/maker/project_discovery_test.rb`

- [ ] **Step 1: Write the tests**

Append inside `ProjectDiscoveryTest`:

```ruby
    test "a run over the cap adopts deterministically and says it was capped" do
      dir("d-c", "Gamma", "d-projects")
      dir("d-a", "Alpha", "d-projects")
      dir("d-b", "Beta", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user, cap: 2)

      assert_equal :capped, run.status
      assert_equal 2, run.created
      assert_equal 3, run.candidates
      # ORDERED BY node_id, so a second run continues where this one stopped rather than
      # re-rolling the dice.
      assert_equal %w[d-a d-b], @user.maker_projects.order(:folder_node_id).pluck(:folder_node_id)
    end

    test "the next run continues where a capped run stopped" do
      dir("d-a", "Alpha", "d-projects")
      dir("d-b", "Beta", "d-projects")
      Maker::ProjectDiscovery.for_user(user: @user, cap: 1)

      run = Maker::ProjectDiscovery.for_user(user: @user, cap: 1)

      assert_equal :ok, run.status
      assert_equal %w[d-a d-b], @user.maker_projects.order(:folder_node_id).pluck(:folder_node_id)
    end

    # `Integer("-5")` SUCCEEDS, so a rescue never sees a negative — it reaches `first(-5)` and
    # raises "negative array size" from inside a recurring job, far from the typo.
    test "a nonsense cap override falls back instead of crashing" do
      dir("d-lamp", "Desk Lamp", "d-projects")

      ENV["PROJECT_DISCOVERY_MAX"] = "-5"
      assert_equal Maker::ProjectDiscovery::MAX_PROJECTS, Maker::ProjectDiscovery.max_projects
      assert_nothing_raised { Maker::ProjectDiscovery.for_user(user: @user) }

      ENV["PROJECT_DISCOVERY_MAX"] = "0"
      assert_equal Maker::ProjectDiscovery::MAX_PROJECTS, Maker::ProjectDiscovery.max_projects

      ENV["PROJECT_DISCOVERY_MAX"] = "banana"
      assert_equal Maker::ProjectDiscovery::MAX_PROJECTS, Maker::ProjectDiscovery.max_projects
    ensure
      ENV.delete("PROJECT_DISCOVERY_MAX")
    end

    test "a valid cap override is honoured" do
      ENV["PROJECT_DISCOVERY_MAX"] = "7"

      assert_equal 7, Maker::ProjectDiscovery.max_projects
    ensure
      ENV.delete("PROJECT_DISCOVERY_MAX")
    end
```

- [ ] **Step 2: Run and verify they pass**

```bash
bin/rails test test/services/maker/project_discovery_test.rb
```

Expected: PASS, 16 tests.

- [ ] **Step 3: Mutation-check the fallback**

Change `value.positive? ? value : MAX_PROJECTS` to just `value` and re-run.

Expected: "a nonsense cap override falls back instead of crashing" goes **RED** with `ArgumentError: negative array size`. Restore.

- [ ] **Step 4: Commit**

```bash
git add test/services/maker/project_discovery_test.rb
git commit -m "Pin ProjectDiscovery's cap — deterministic, resumable, nonsense override falls back"
```

---

## Task 7: `Maker::ProjectDiscoveryJob`

**Files:**
- Create: `app/jobs/maker/project_discovery_job.rb`
- Test: `test/jobs/maker/project_discovery_job_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/jobs/maker/project_discovery_job_test.rb`:

```ruby
require "test_helper"

module Maker
  class ProjectDiscoveryJobTest < ActiveJob::TestCase
    setup do
      @user = User.create!(email: "pdj-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    # THE BACKEND GATE LIVES ON THE FAN-OUT, NOT ON #perform — Library::ScanJob's own comment has
    # the argument: a SCHEDULE may no-op, but a COMMAND naming a user must not silently do nothing.
    test "the scheduled fan-out declines on a scannable backend" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("pdj"))

      assert_no_enqueued_jobs { Maker::ProjectDiscoveryJob.sweep_all! }
    end

    # THE POSITIVE CONTROL FOR THE ASSERTION ABOVE, and it is not decoration:
    # `assert_no_enqueued_jobs` passes just as happily over a `sweep_all!` that returns
    # unconditionally, or over a harness not observing enqueues at all. Only this arm tells "the
    # gate declined" from "the fan-out never worked".
    test "the scheduled fan-out enqueues on a non-scannable backend" do
      FileLayer.current = FileLayer::ChunkRemote.new

      assert_enqueued_with(job: Maker::ProjectDiscoveryJob, args: [ { user_id: @user.id } ]) do
        Maker::ProjectDiscoveryJob.sweep_all!
      end
    end

    # #perform CARRIES NO GATE, so an explicit caller gets the sweep on any backend.
    test "perform sweeps on a scannable backend too" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("pdj"))
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "Desk Lamp", "d-projects")

      run = Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)

      assert_equal 1, run.created
      assert_equal "Desk Lamp", @user.maker_projects.sole.name
    end

    # THE CHAIN. Without it a chunk_remote user waits a SECOND 15-minute tick between "the folder
    # became a project" and "its files got attached and filed".
    test "a run that created something chains the intake on a non-scannable backend" do
      FileLayer.current = FileLayer::ChunkRemote.new
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "Desk Lamp", "d-projects")

      assert_enqueued_with(job: Maker::ProjectIntakeJob, args: [ { user_id: @user.id } ]) do
        Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)
      end
    end

    test "a run that created nothing chains nothing" do
      FileLayer.current = FileLayer::ChunkRemote.new
      dir("d-projects", "Projects", nil)

      assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
        Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)
      end
    end

    # GATED ON !scannable? AND THAT GATE IS NOT OPTIONAL. On share/s3 Library::ScanJob already
    # sequences discovery -> intake -> catalog inside ONE perform. A second, unsequenced filer is
    # the §14f scan-overlap bug: a move made after the Scanner captured its observations is paired
    # back by (content_hash, size), leaving the node at a path with no bytes and a download
    # returning a TERMINAL 404.
    test "the chain does not fire on a scannable backend" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("pdj"))
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "Desk Lamp", "d-projects")

      assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
        run = Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)
        assert_equal 1, run.created, "precondition: the run must have created something to chain"
      end
    end

    test "a deleted user is discarded rather than failed" do
      assert_nothing_raised do
        Maker::ProjectDiscoveryJob.perform_now(user_id: 0)
      end
    end

    teardown { FileLayer.reset! }
  end
end
```

- [ ] **Step 2: Run and verify they fail**

```bash
bin/rails test test/jobs/maker/project_discovery_job_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Maker::ProjectDiscoveryJob`.

- [ ] **Step 3: Implement**

Create `app/jobs/maker/project_discovery_job.rb`:

```ruby
module Maker
  # The scheduled half of Maker::ProjectDiscovery. Mirrors Maker::ModelIntakeJob down to why each
  # decision is what it is — read that file, and Maker::ProjectIntakeJob before it.
  class ProjectDiscoveryJob < ApplicationJob
    queue_as :background

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    # ONE SWEEP PER USER AT A TIME, and it is load-bearing here in a way it is not for
    # ModelIntakeJob: maker_projects has a unique index on (user_id, slug) but NONE on
    # folder_node_id, so two concurrent sweeps would both see one folder unclaimed and mint
    # `desk-lamp` AND `desk-lamp-2` pointing at the same node. :discard because a queued second
    # sweep re-does the first one's work; the 15-minute schedule IS the retry, and it re-reads the
    # world rather than replaying a stale verdict.
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 15.minutes, on_conflict: :discard

    def perform(user_id:)
      user = User.find(user_id)
      run = Maker::ProjectDiscovery.for_user(user:)
      if run.created.positive? || run.status == :capped
        Rails.logger.info("Maker::ProjectDiscoveryJob: user #{user.id} created #{run.created} " \
                          "of #{run.candidates} candidates, status #{run.status}")
      end
      chain_intake(user) if run.created.positive?
      run
    end

    # THE GATE IS HERE AND NOT IN #perform, matching Library::ScanJob.scan_all! and both sibling
    # sweeps: on a scannable backend Library::ScanJob already calls discovery at the start of its
    # own post-reconcile sequence. A second caller would adopt folders the reconcile has not
    # settled yet. It asks a CAPABILITY rather than a class, per the Phase 3 trap `is_a?(Share)`
    # shipped: a gate that names classes answers false for the next backend and silently never runs.
    def self.sweep_all!
      return if FileLayer.current.capabilities.scannable?

      User.find_each { |user| perform_later(user_id: user.id) }
    end

    private

    # THE ONE THING ModelIntakeJob DOES NOT DO. Without it a chunk_remote user waits a SECOND
    # 15-minute tick between "the folder became a project" and "its files got attached and filed" —
    # two ticks to see anything happen, on a feature whose whole point is that dropping a folder in
    # just works.
    #
    # GATED ON !scannable?, AND THAT GATE IS NOT OPTIONAL. On share/s3 Library::ScanJob sequences
    # discovery -> intake -> catalog inside ONE perform. A second, unsequenced filer is exactly the
    # scan-overlap bug §14f records: a move made after the Scanner captured its observations is
    # paired back by (content_hash, size), re-pointing the node at its OLD path while the bytes sit
    # at the new one — and a download in that window gets Share#download's ENOENT -> NotFound -> a
    # TERMINAL 404, not the retryable 503.
    #
    # A TRIGGER, NOT A SECOND COPY OF THE POLICY — the same reading Maker::ProjectIntakeJob
    # .nudge_parents records. Nothing here decides where a file goes; it only makes the one sweep
    # happen sooner, and ProjectIntakeJob's own limits_concurrency collapses duplicates.
    #
    # BEST-EFFORT: a discovery run that has already committed its rows must not fail because a
    # follow-on could not be enqueued.
    def chain_intake(user)
      return if FileLayer.current.capabilities.scannable?

      Maker::ProjectIntakeJob.perform_later(user_id: user.id)
    rescue StandardError => e
      Rails.logger.warn("Maker::ProjectDiscoveryJob: created projects for user #{user.id} but " \
                        "could not enqueue the intake: #{e.class}: #{e.message}")
    end
  end
end
```

- [ ] **Step 4: Run and verify they pass**

```bash
bin/rails test test/jobs/maker/project_discovery_job_test.rb
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Mutation-check the chain gate**

Delete the `return if FileLayer.current.capabilities.scannable?` line from `#chain_intake` and re-run.

Expected: "the chain does not fire on a scannable backend" goes **RED**. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/jobs/maker/project_discovery_job.rb test/jobs/maker/project_discovery_job_test.rb
git commit -m "Maker::ProjectDiscoveryJob — scheduled sweep, gated fan-out, chunk_remote chain"
```

---

## Task 8: Wire into `Library::ScanJob`, before the filing sweep

**Files:**
- Modify: `app/jobs/library/scan_job.rb`
- Test: `test/jobs/library/scan_job_test.rb`

- [ ] **Step 1: Write the failing ordering test**

Append to `test/jobs/library/scan_job_test.rb`, as a sibling class beside `IntakeOrderTest`:

```ruby
  # DISCOVERY RUNS AFTER THE RECONCILE AND BEFORE THE FILING SWEEP, and both orderings change the
  # ANSWER rather than the timing. This drives the whole feature end to end through the only door a
  # share deployment has: someone makes Projects/Desk Lamp/ in Finder and drops a file in it.
  class DiscoveryOrderTest < ActiveSupport::TestCase
    setup do
      @root = Dir.mktmpdir
      @user = User.create!(email: "job-#{SecureRandom.hex(6)}@example.com")
      # A Share adapter rooted at @root, so the intake's own move (Maker::MoveNode ->
      # FileLayer.current.move) lands on the same directory the scan just read.
      FileLayer.current = FileLayer::Share.new(root: @root)

      # ON DISK ONLY — no project row, no node rows. This is the feature's whole subject.
      FileUtils.mkdir_p(File.join(@root, "Projects", "Desk Lamp"))
      File.binwrite(File.join(@root, "Projects", "Desk Lamp", "panel.svg"), "<svg/>")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    test "one perform discovers the project AND attaches and files its loose file" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      project = @user.maker_projects.sole
      assert_equal "Desk Lamp", project.name
      assert_equal "desk-lamp", project.slug

      att = project.file_attachments.sole
      node = @user.nodes.find_by!(node_id: att.node_id)
      assert_equal "panel.svg", node.name
      assert_equal "vector", att.role
      assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name,
                   "discovery ran BEFORE the project intake — the intake filed a folder that " \
                   "discovery had only just adopted. Swap the two calls in ScanJob#perform and " \
                   "this goes red: the file stays at the project root, where the seeded `*` shelf " \
                   "makes the whole folder one model, permanently."
    end

    # THE CATEGORY FOLDER GOES UNDER THE FOLDER THE USER MADE, not a second `Projects/desk-lamp/`
    # tree rebuilt from the slug. See Task 3 — this is that fix, driven through the real door.
    test "the category folder is created under the discovered folder, not a slug-named twin" do
      Library::ScanJob.perform_now(user_id: @user.id, root: @root)

      assert_path_exists File.join(@root, "Projects", "Desk Lamp", "design", "panel.svg")
      refute File.exist?(File.join(@root, "Projects", "desk-lamp")),
             "no second Projects/<slug> tree may be minted"
    end
  end
```

- [ ] **Step 2: Run and verify it fails**

```bash
bin/rails test test/jobs/library/scan_job_test.rb
```

Expected: FAIL — `@user.maker_projects.sole` raises, no project was created.

- [ ] **Step 3: Add the step to `#perform`**

In `app/jobs/library/scan_job.rb`, `#perform` becomes:

```ruby
    def perform(user_id:, root: nil)
      user = User.find(user_id)

      observer = root ? Library::Scanner.new(user, root:) : observer_for(user)
      observer.call
      warn_unreadable(observer, user)
      discover_projects(user)
      intake_project_folders(user)
      intake_models(user)
    end
```

- [ ] **Step 4: Add the private method**

In `app/jobs/library/scan_job.rb`, immediately **above** `#intake_project_folders`:

```ruby
    # STRICTLY AFTER THE RECONCILE AND STRICTLY BEFORE THE PROJECT INTAKE, and BOTH orderings
    # change the ANSWER rather than the timing.
    #
    # After the RECONCILE because discovery reads names and parentage, and a folder the Scanner has
    # not settled is a wrong answer — the same reason the two methods below give.
    #
    # Before the PROJECT INTAKE because a discovered project's loose files must be filed in the SAME
    # pass. Left at `Projects/new-thing/`, the seeded `*` shelf makes `Projects` the nearest shelf
    # above them, so the whole `new-thing` FOLDER becomes one model titled "new-thing" — and nothing
    # reaps an auto model, so the wrong row is permanent. That is #intake_models' own IntakeOrderTest
    # hazard, one step earlier in the chain. Pinned by DiscoveryOrderTest, which is RED on the swap.
    #
    # CALLS THE JOB, NOT Maker::ProjectDiscovery DIRECTLY, for the reason #intake_project_folders
    # records as a finding rather than a preference: the SERVICE logs nothing, so the JOB is the
    # only place a run's created count is ever written down. Calling the service here would give a
    # share/s3 deployment LESS operator visibility than chunk_remote gets from its schedule.
    # Concurrency controls apply at ENQUEUE, so ProjectDiscoveryJob's own limit cannot discard this
    # perform_now — and its #chain_intake declines on a scannable backend, so this call cannot
    # enqueue a second, unsequenced filer.
    #
    # RESCUED AND NARROWLY SCOPED, like its two siblings: the reconcile above is already committed,
    # so a discovery bug must not tell an operator reading the failed-jobs table that the library
    # did not index.
    def discover_projects(user)
      Maker::ProjectDiscoveryJob.perform_now(user_id: user.id)
    rescue StandardError => e
      Rails.logger.error("Library::ScanJob: the reconcile SUCCEEDED but project discovery " \
                         "failed for user #{user.id}: #{e.class}: #{e.message}")
    end
```

- [ ] **Step 5: Run and verify it passes**

```bash
bin/rails test test/jobs/library/scan_job_test.rb
```

Expected: PASS, including the pre-existing `IntakeOrderTest`.

- [ ] **Step 6: Mutation-check the ordering**

Swap `discover_projects(user)` and `intake_project_folders(user)` in `#perform` and re-run.

Expected: "one perform discovers the project AND attaches and files its loose file" goes **RED** — `parent_node_id` resolves to `Desk Lamp`, not `design`. Restore and confirm green.

- [ ] **Step 7: Commit**

```bash
git add app/jobs/library/scan_job.rb test/jobs/library/scan_job_test.rb
git commit -m "ScanJob: discover projects after the reconcile, before the filing sweep"
```

---

## Task 9: The schedule and the rake task

**Files:**
- Modify: `config/recurring.yml`
- Modify: `lib/tasks/projects.rake`

- [ ] **Step 1: Add the recurring entry**

In `config/recurring.yml`, insert immediately **above** the `project_folder_intake` entry:

```yaml
  # Auto-create a project for every folder directly under the library's Projects/ that no project
  # claims. CHUNK DEPLOYMENTS ONLY — sweep_all! declines when the backend is `scannable`, because on
  # share/s3 Library::ScanJob calls discovery at the start of its own post-reconcile sequence,
  # strictly BEFORE the project intake. A second caller there would adopt folders the reconcile has
  # not settled yet.
  #
  # `command:` rather than `class:`, matching every other gated entry here, because the backend gate
  # lives in a class method rather than in #perform — a caller who names a user deserves the
  # operation.
  #
  # EVERY 15 MINUTES, matching its two siblings — and arbitrary for the same reason
  # project_folder_intake states below: on chunk_remote there is no poll behind it, so this interval
  # is the ONLY latency bound discovery gets. It is not a floor inherited from anything.
  #
  # A RUN THAT CREATES SOMETHING CHAINS Maker::ProjectIntakeJob rather than waiting for the next
  # project_folder_intake tick, so a newly adopted folder's files are filed seconds later instead of
  # up to fifteen minutes later. See ProjectDiscoveryJob#chain_intake for why that chain is gated
  # off scannable backends.
  project_discovery:
    command: "Maker::ProjectDiscoveryJob.sweep_all!"
    schedule: every 15 minutes
```

- [ ] **Step 2: Verify the YAML parses and the command resolves**

```bash
bin/rails runner 'c = YAML.load_file("config/recurring.yml").fetch("production").fetch("project_discovery"); puts c["command"]; puts Maker::ProjectDiscoveryJob.respond_to?(:sweep_all!)'
```

Expected:
```
Maker::ProjectDiscoveryJob.sweep_all!
true
```

- [ ] **Step 3: Add the rake task**

In `lib/tasks/projects.rake`, inside `namespace :projects do`, above the existing `organize` task:

```ruby
  desc "Create a project for every unclaimed folder under Projects/ (PROJECT_DISCOVERY_MAX raises the cap)"
  task discover: :environment do
    User.find_each do |user|
      run = Maker::ProjectDiscovery.for_user(user:)
      # Silent for a user with nothing to adopt — Maker::ProjectIntakeJob#report's own rule, so a
      # steady-state run prints nothing rather than a row per user per invocation.
      next if run.created.zero? && run.status != :capped

      puts "user #{user.id}: created #{run.created} of #{run.candidates} candidates, " \
           "status #{run.status}"
      puts "  capped at #{run.cap} - run again to continue" if run.status == :capped
    end
  end
```

- [ ] **Step 4: Verify the task loads and runs**

```bash
bin/rails projects:discover
```

Expected: exits 0. Output is empty on a database with nothing to adopt — that is the intended silence, not a failure.

- [ ] **Step 5: Commit**

```bash
git add config/recurring.yml lib/tasks/projects.rake
git commit -m "Schedule project discovery and add rake projects:discover"
```

---

## Task 10: Docs — move §14f to an area file

CLAUDE.md is **1,487 lines against a 1,500-line ceiling** (`test/docs_hygiene_test.rb`), so discovery's rules cannot go inline. §14f is **143 lines** binding on one subsystem — the documented profile for an area file.

**Files:**
- Create: `docs/invariants/project-intake.md`
- Modify: `CLAUDE.md` (§14f → stub)
- Modify: `test/docs_hygiene_test.rb` (ratchet `MAX_LINES` down)
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Confirm the section boundaries before cutting**

```bash
awk '/^### 14f\./{s=NR} /^### 14g\./{print "14f spans", s, "-", NR-1; exit}' CLAUDE.md
```

Expected: `14f spans 1106 - 1248`. If the numbers differ, use what this prints — a previous task may have shifted them.

- [ ] **Step 2: Create the area file**

Create `docs/invariants/project-intake.md` with this header, then paste the **entire body of §14f** (every bullet, verbatim, from the line after `### 14f. Project-folder intake` through the line before `### 14g.`) beneath the `## Filing` heading:

```markdown
# Project-folder intake and discovery

> CLAUDE.md §14f's area file. Read before touching `app/services/maker/project_intake.rb`,
> `app/services/maker/project_discovery.rb`, `app/services/maker/attach_to_project.rb`,
> `app/services/maker/project_folders.rb`, `app/jobs/maker/project_intake_job.rb`,
> `app/jobs/maker/project_discovery_job.rb`, or `Library::ScanJob`'s post-reconcile sequence. The
> arcs that produced it are in `docs/STATUS.md`.

## Discovery — a folder under `Projects/` becomes a project

- **STATELESS: POSITION IS THE MARKER.** Any live dir directly under `Projects/` that no project
  claims becomes a project. There is no watermark, no "adopted" column and no first-run exemption —
  the same rule the filing sweep states below, one level up.
- **THE CLAIM LOOKUP IS UNSCOPED, AND THAT IS THE ENTIRE DISMISSAL MECHANISM.** An archived project
  keeps its `folder_node_id`, so the sweep passes over its folder forever. Filtering archived rows
  out of the sweep's OWN lookup is precisely how a dismissed thing comes back —
  `docs/invariants/model-intake.md` records the identical mistake for the `catalogued` scope. **The
  row is the memory.** Consequence, stated rather than discovered:
  `V1::Maker::ProjectsController#destroy` hard-deletes, so a device deleting a project whose folder
  still exists gets it back on the next tick. The web UI is unaffected — `ProjectsController#destroy`
  archives.
- **IT NEVER MINTS `Projects/` AND NEVER CALLS `ensure_library_folder!`.** A user with no `Projects/`
  folder is not swept (`status: :no_projects_folder`). Creating it as a side effect of merely looking
  is `Projects::AttachmentsController#relocate`'s recorded bug at library-sweep scale.
- **DIRECT CHILDREN ONLY, AND DOT-FOLDERS ARE SKIPPED.** `Projects/desk-lamp/models/` is a category
  folder this app created; adopting it mints a project named "models" inside a project. And **`.git`
  keeps its node** (§14b — the marker is the evidence a directory is a working tree), so without the
  dot rule a repo checked out at the `Projects/` root becomes a project literally titled `.git`.
- **DISCOVERY RUNS STRICTLY BEFORE THE FILING SWEEP, AND THE ORDER CHANGES THE ANSWER.** A discovered
  project's loose files left at its root have no shelf nearer than `Projects` (the seeded `*`), so
  the whole folder becomes ONE model — and nothing reaps an auto model, so the wrong row is
  permanent. `Library::ScanJob` sequences the two inline; on `chunk_remote`
  `ProjectDiscoveryJob#chain_intake` enqueues the intake when a run created something, **gated off
  scannable backends** because a second unsequenced filer there is the scan-overlap bug below.
- **THE SWEEP NEVER CALLS THE PORT.** It writes `maker_projects` rows and nothing else, which is what
  makes it identical on all three backends and testable without a library on disk.
- **ONE CAP, NOT TWO.** `MAX_PROJECTS` bounds an unattended run's churn and is absolute rather than a
  percentage, because the intended first run adopts 100% of what is there. Nothing in a browser
  request discovers — the web doors' eager nudge calls `Maker::ProjectIntake.for_node` directly and
  never routes through a job. **Whoever adds a nudge owes the second cap.** A nonsense override falls
  back rather than crashing: `Integer("-5")` SUCCEEDS, so a negative reaches `first(-5)` and raises
  "negative array size" from inside a recurring job.
- **THE SLUG IS `Maker::Project.available_slug`, NOT `#ensure_slug`.** A sweep cannot surface a
  validation error to anyone, so it needs import's collision-proof treatment — and `#ensure_slug`
  keeps today's behaviour, because a human typing a duplicate name into the web form SHOULD be told.
  Two reachable raises without it: two folders slugifying the same, and **any purely non-Latin name**,
  which reduces to `""` under `gsub(/[^a-z0-9]+/, "-")`.
- **`#place` RESOLVES ITS DESTINATION UNDER THE PROJECT'S FOLDER NODE, NEVER A PATH REBUILT FROM THE
  SLUG.** A discovered project's folder is named whatever the user named it (`Projects/Desk Lamp`,
  slug `desk-lamp`), so rebuilding the path mints a SECOND tree and moves the file into it, leaving
  the folder the user made looking empty. This is also what makes `#place` agree with
  `.destination_for` about the parent, which the filing rules below already require about the name.

## Filing

<!-- paste the entire body of CLAUDE.md §14f here, verbatim -->
```

- [ ] **Step 3: Replace §14f in CLAUDE.md with a stub**

Delete CLAUDE.md lines 1106–1248 (the `### 14f.` heading and its body, up to but not including `### 14g.`) and put this in their place:

```markdown
### 14f. Project-folder intake and discovery → **`docs/invariants/project-intake.md`**

**Read that file before touching** `app/services/maker/project_intake.rb`,
`app/services/maker/project_discovery.rb`, `app/services/maker/attach_to_project.rb`,
`app/services/maker/project_folders.rb`, `app/jobs/maker/project_intake_job.rb`,
`app/jobs/maker/project_discovery_job.rb`, or `Library::ScanJob`'s post-reconcile sequence. It holds
the root-is-inbox sort rule, why it is a sweep and not a hook per door, the two collision checks and
their 409/422 split, the two caps and the backend-aware eager cap, the eager-nudge rules — and
DISCOVERY: the unscoped claim lookup (archiving is the dismissal), never minting `Projects/`, direct
children only, dot-folders skipped, and discovery strictly before the filing sweep. Moved out on
2026-08-26 because it is *area* knowledge — 143 lines paid for on every session and needed on few.
Nothing was dropped; this anchor stays, because **16 references across 10 files under `app/`** plus
10 test files cite `§14f` (measured 2026-08-26).
```

- [ ] **Step 4: Ratchet the ceiling down**

```bash
wc -l CLAUDE.md
```

Take that number, round **up** to the next multiple of 50, and set it in `test/docs_hygiene_test.rb`:

```ruby
  MAX_LINES = 1_400
```

(1,400 is the expected value for ~1,358 lines. Use whatever the rounding gives — the ceiling is a **ratchet**: lowering it as the file shrinks is the rule.)

- [ ] **Step 5: Run the docs guard**

```bash
bin/rails test test/docs_hygiene_test.rb
```

Expected: PASS — all three tests. The new `docs/invariants/project-intake.md` is cited by the stub, and the stub's path resolves.

- [ ] **Step 6: Mutation-check the ratchet**

Set `MAX_LINES = 1_000` and re-run.

Expected: "CLAUDE.md stays under its line ceiling" goes **RED**. Restore the real value.

- [ ] **Step 7: Add the STATUS.md entry**

§15: `docs/STATUS.md` is part of the work, in the same branch and the same PR. Add one entry for this arc (not one per commit), covering:

- what shipped — `Maker::ProjectDiscovery`, its job, the `ScanJob` step, the schedule, the rake task;
- the design decisions that cost something: no migration (archiving is the dismissal, unscoped claim lookup), one cap not two, the `chain_intake` gate;
- **the bug Task 3 found** — `#place` rebuilt its destination path from the slug while `.destination_for` resolved it under the folder node, so a discovered project would have minted a second `Projects/<slug>/` tree and scattered the user's files into it. Latent before discovery (reachable by renaming a project's slug), mainline after;
- the §14f move and the ceiling ratchet, with the measured line counts;
- the three consequences the spec documents rather than fixes (v1 hard-delete resurrection, the chunk_remote model-catalog race, adoption reorganizing a folder).

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md docs/invariants/project-intake.md test/docs_hygiene_test.rb docs/STATUS.md
git commit -m "Move §14f to docs/invariants/project-intake.md, add discovery's rules, ratchet the ceiling"
```

---

## Task 11: Full verification

**Files:** none — this task only runs gates.

- [ ] **Step 1: Run the whole local gate set**

```bash
bin/ci
```

Expected: every gate green. `test-chunk-remote` needs `../tinkerex-sync` checked out:

```bash
gh repo clone chaim354/tinkerex-sync ../tinkerex-sync
```

- [ ] **Step 2: Compare the three backend legs**

`bin/ci` **prints** the three counts and never compares them — the rule has always relied on a human reading them. Read the run counts from `test` (share), `test-s3` and `test-chunk-remote` and confirm they match.

A ±2 assertion / ±1 skip difference is the known pre-existing flap recorded in `docs/STATUS.md` under "Still open". **A structural difference means a test depends on the ambient `LIBRARY_BACKEND` and is a real bug** — discovery is DB-only and must behave identically on all three.

- [ ] **Step 3: Confirm the architecture guard still passes**

```bash
bin/rails test test/architecture_invariants_test.rb test/ci_hygiene_test.rb test/docs_hygiene_test.rb
```

Expected: PASS. Nothing added here names `Sync::`, and the seam guard asserts zero references with no allowlist.

- [ ] **Step 4: Finish the branch**

Gates green on a `claude/*` branch is standing authorization to commit, push and open a PR (§15) — use `/finish-branch`. State plainly in the PR what was verified and what was not:

- **Verified:** all gates, the three backend legs, and every mutation-check listed in Tasks 1–10.
- **Not verified:** behaviour on a real Unraid deployment. Discovery has never run against a live `Projects/` folder, and the first run on the share deployment will adopt every unclaimed folder there at once — worth a `rake projects:discover` dry look before the schedule fires.

**Do not merge.** Merging always needs an explicit go-ahead.

---

## Appendix: the mutation-check ledger

Every guard in this plan, and the edit that must turn it red. A guard that has never failed has not been shown to work (§15).

| Task | Guard | Mutation |
|---|---|---|
| 1 | Projects literal drift | put `"Projects"` back in `project.rb` |
| 2 | web form still errors on a duplicate name | `#ensure_slug` calls `available_slug` |
| 3 | destination under the folder node | restore `ensure_path!([ROOT, slug, dest])` |
| 4 | a sweep cannot raise on a slug | drop the `slug:` argument from `for_user`'s `create!` |
| 5 | archived project claims its folder | add `.where(archived_at: nil)` to the claim lookup |
| 5 | dot-folders skipped | delete the `start_with?(".")` clause |
| 5 | direct children only | drop the `parent_node_id` clause |
| 5 | files are not folders | drop `kind: "dir"` |
| 5 | tombstones are not adopted | drop `.present` |
| 5 | never mints `Projects/` | `projects_root` → `ensure_path!` |
| 6 | nonsense cap falls back | `value.positive? ? value : MAX_PROJECTS` → `value` |
| 7 | the chain is gated | delete `return if ...scannable?` from `#chain_intake` |
| 8 | discovery before filing | swap the two calls in `ScanJob#perform` |
| 10 | the ceiling is real | set `MAX_LINES = 1_000` |
