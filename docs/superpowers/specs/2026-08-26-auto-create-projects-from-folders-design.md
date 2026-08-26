# Auto-create a project from a folder under `Projects/`

**Date:** 2026-08-26
**Branch:** `claude/auto-create-projects-folders-7725e3`
**One line:** a live folder directly under the library's `Projects/` that no project claims becomes
a `Maker::Project`.

---

## 1. What this is

Today a `Projects/<slug>/` folder only exists because a project made it —
`Maker::Project#ensure_library_folder!` mints it. The catalog is authoritative and the library
follows. This inverts that for one case: a maker who drops `Projects/Desk Lamp/` onto the NAS in
Finder, or whose desktop client syncs one down, gets a project for it.

It is the same shape as `Maker::ModelIntake` one level up — a **sweep over `nodes`**, the catalog
all three backends populate, which is why it needs no per-door hook and covers every door present
and future.

**Not in scope:** nothing about how a project's files are attached or filed. That is
`Maker::ProjectIntake`'s job already, and it starts working on a discovered folder the moment
`folder_node_id` is set. Discovery only mints the row.

---

## 2. The rule

`Maker::ProjectDiscovery.for_user(user:, cap: nil) → RunResult(created:, candidates:, status:, cap:)`

`created` is **this run's delta** — rows actually written — so a steady-state sweep reports 0 rather
than the number of projects the user has. `candidates` is how many adoptable folders step 4 left,
which is what makes `:capped` legible ("created 50 of 63") and is the only reason it exists; there
is deliberately no per-reason `skips` breakdown, because the dominant "skip" is *already claimed*,
which is the steady state and would print a number every tick that means nothing happened.

1. Resolve the `Projects` root: `user.nodes.present.find_by(parent_node_id: nil, name:
   Maker::ProjectFolders::ROOT, kind: "dir")` — `parent_node_id: nil` **is** the library root, the
   representation `Library::Reconciler` and `Maker::LibraryTree` both use. Absent →
   `status: :no_projects_folder`, create nothing.
2. Candidates: `user.nodes.present.where(parent_node_id: <root>, kind: "dir")`. **Direct children
   only.**
3. Drop any name beginning with `.`.
4. Drop any node_id in `user.maker_projects.pluck(:folder_node_id)`.
5. Sort by `node_id`, take `first(cap)`.
6. For each: `user.maker_projects.create!(name: <folder name, verbatim>, slug:
   Maker::Project.available_slug(user, from: <folder name>), folder_node_id: <folder node_id>)`.

`status` is `:ok`, `:capped`, or `:no_projects_folder`. A caller has to be able to tell "your
library is catalogued" from "there is more of it than one run will do" — `Maker::ModelIntake`'s
`RunResult` makes the same distinction for the same reason.

### Decisions behind each step, and what breaks without them

**Step 1 — never mint the root.** Calling `ensure_library_folder!`, or any `mkdir`, would create
`Projects/` on every library that has never had one, as a side effect of merely looking. That is
`Projects::AttachmentsController#relocate`'s recorded bug at library-sweep scale, and
`docs/invariants/model-intake.md` states the same rule for the model sweep ("THE SWEEP NEVER CALLS
THE PORT AND NEVER CALLS `ensure_library_folder!`"). A user with no `Projects/` folder is simply
not swept.

**Step 2 — direct children only.** `Projects/desk-lamp/models/` is a category subfolder
`Maker::ProjectFolders` created; adopting it would mint a project named "models" inside a project.
The shape of a project folder is `Projects/<name>` and nothing deeper.

**Step 3 — dot-folders.** `Library::OsClutter` already stops `.DS_Store`, `__MACOSX` and the rest
from ever becoming nodes, but **`.git` is the one skip that keeps its entry** (CLAUDE.md §14b — the
marker is the evidence a directory is a working tree, and `Maker::AttachToProject`'s
`:in_working_tree` asks the database for it). So without this rule, a repo checked out at the
`Projects/` root produces a project literally titled `.git`. The leading dot is the general form of
that rule, not a special case for one name.

**Step 4 — the claim lookup is UNSCOPED, and that is the whole dismissal mechanism.** Archiving a
project leaves `folder_node_id` intact, so an archived project still claims its folder and the
sweep passes over it. Filtering archived rows out of this lookup is precisely how a dismissed thing
comes back — `docs/invariants/model-intake.md` records exactly this mistake for the `catalogued`
scope. **The row is the memory.**

**Step 5 — deterministic order.** A capped run must be reproducible, and the next run must continue
where this one stopped rather than re-rolling the dice. `Maker::ModelIntake` sorts its `todo` for
the same reason.

**Step 6 — the name is verbatim, the slug is derived.** A folder named `Desk Lamp` yields a project
*named* "Desk Lamp" with slug `desk-lamp`. The folder is never renamed to match the slug: the
project's `folder_node_id` points at the folder that exists, and `ensure_library_folder!` returns it
untouched because the node is live.

---

## 3. Two supporting changes

### 3a. A slug an unattended run can't fail on

`Maker::Project#ensure_slug` deliberately does **not** de-duplicate, and `Maker::Model#ensure_slug`'s
own comment names why:

> Friendly URLs + collision-proof: two "Benchy" imports must both succeed, so a taken slug gets -2,
> -3, ... (Project fails validation on collision; import can't afford that).

That is right for the web form — a human typing a duplicate name should be told. **A sweep can't
afford it either, for the same reason import can't: nobody is there to read the error.** Two
reachable failures:

- **Collision.** `Projects/desk-lamp` (a real project's folder) beside `Projects/Desk Lamp` (one the
  user made by hand) — both slugify to `desk-lamp`, and `create!` raises `RecordInvalid` inside the
  recurring job.
- **Blank.** `ensure_slug` is `downcase.gsub(/[^a-z0-9]+/, "-")`, so **any purely non-Latin folder
  name reduces to `""`** — `プロジェクト`, `Проект`, `模型` — and `validates :slug, presence: true`
  raises. Not an exotic case.

So:

- Extract `Maker::Project.slugify(str)` — the existing normalization, unchanged, in one place.
- Add `Maker::Project.available_slug(user, from:)` — slugify, fall back to `"project"` when blank,
  then `-2`, `-3`, … until free.
- `#ensure_slug` calls `slugify` and otherwise **behaves exactly as it does today**: no de-dup, still
  fails validation on a collision. The web form's honest error is preserved; only the sweep gets the
  import treatment.

Discovery passes `slug:` explicitly, and that is stable through the callback: `ensure_slug` reads
`slug.presence || name`, so `"desk-lamp-2"` normalizes to itself.

### 3b. `Maker::ProjectFolders::ROOT = "Projects"`

The literal is hardcoded in two places today — `Maker::Project#ensure_library_folder!` and
`Maker::ProjectIntake#place`'s `ensure_path!`. Discovery would be the third, and three copies of a
string that must agree is the drift shape this repo has paid for twice (`FilesHelper::EXT_FAMILIES`
vs `ROLE_BY_EXT`; `preview_kind`'s inline extension list). `Maker::ProjectFolders` is already the
module that owns "what the folders under a project are called".

### 3c. `#place` must resolve under the project's folder NODE — a bug this feature exposes

*Added 2026-08-26 while writing the implementation plan; not in the first draft of this spec.*

`Maker::ProjectIntake#place` builds its destination as `ensure_path!([ROOT, @project.slug, dest])` —
a path **rebuilt from the slug** — while `Maker::ProjectIntake.destination_for` resolves the same
folder under the project's actual `folder_node_id`. §14f already requires that prediction and
behaviour cannot disagree; they agree on the folder *name* and **not on its parent**, and that has
gone unnoticed because `#ensure_library_folder!` is the only writer of `folder_node_id` and always
mints `Projects/<slug>`, so the two coincide.

**Discovery makes them diverge as the mainline case.** A project adopted from `Projects/Desk Lamp`
has slug `desk-lamp`, so `#place` would mint a **second** `Projects/desk-lamp/` tree and move the
user's file into it — leaving the folder they made looking empty while the project still points at
it. Nothing errors and nothing logs.

**The fix:** `Maker::LibraryFolder.create_child!(@user, parent_node_id: live_folder.node_id, name:
dest)` — `ensure_path!`'s single-segment sibling, already find-or-create, so it stays idempotent.
`#live_folder` gains a memo because `#place` now reads it once per file.

**Not a widening of scope, and it is a fix in its own right:** the divergence is reachable today
without discovery — rename a project's slug after its folder was minted and `folder_node_id` keeps
pointing at `Projects/<old-slug>`, which is the same case §5 cites for *not* adding a unique index
on `folder_node_id`.

---

## 4. Wiring

Full parallel to `Maker::ModelIntake` — own service, own job, own `recurring.yml` entry, own
`Library::ScanJob` step, own rake task.

### `Maker::ProjectDiscoveryJob`

Mirrors `Maker::ModelIntakeJob` line for line: `queue_as :background`; `discard_on
ActiveRecord::RecordNotFound` (the user can be deleted between fan-out and run);
`limits_concurrency to: 1, key: user_id, duration: 15.minutes, on_conflict: :discard`; the backend
gate on `sweep_all!` and **not** on `#perform`, because `sweep_all!` is a schedule (declining to
enqueue is a real answer) while `#perform` is a command (a caller named a user, and a silent no-op
there is the failure this port refuses everywhere else).

The concurrency limit is load-bearing here in a way it is not for `ModelIntakeJob`: `maker_projects`
has a unique index on `(user_id, slug)` but **none on `folder_node_id`**, so two concurrent sweeps
would both see one folder unclaimed and mint `desk-lamp` and `desk-lamp-2` pointing at the same
node.

**One addition `ModelIntakeJob` does not have.** When a run created something *and* the backend is
not scannable, enqueue `Maker::ProjectIntakeJob.perform_later(user_id:)`.

- **Why:** without it, a `chunk_remote` user waits a second 15-minute tick between "the folder became
  a project" and "its files got attached and filed". Two ticks to see anything happen is a visible
  wart on a feature whose whole point is immediacy.
- **Why gated on `!scannable?`:** on share/s3 `Library::ScanJob` already sequences discovery →
  intake → catalog inside one `perform`. A second, unsequenced filer is exactly the scan-overlap bug
  §14f records — a move made after the Scanner captured its observations is paired back by
  `(content_hash, size)`, re-pointing the node at its old path while the bytes sit at the new one,
  and a download in that window gets `Share#download`'s `ENOENT` → `NotFound` → a **terminal 404**,
  not the retryable 503. That terminal reading is what makes the ordering worth guaranteeing.
- **This is a trigger, not a second copy of the policy** — the same reading `ProjectIntakeJob
  .nudge_parents` already records. Nothing here decides where a file goes.

### `Library::ScanJob#perform`

```
observer.call → warn_unreadable → discover_projects → intake_project_folders → intake_models
```

`#discover_projects` calls `Maker::ProjectDiscoveryJob.perform_now(user_id:)` — the job, not the
service, for the reason `#intake_project_folders` records as a finding: the service logs nothing, so
the job is the only place a run's counts are ever written down, and calling the service directly
gives a share/s3 deployment *less* operator visibility than `chunk_remote` gets from its schedule.
Same narrow `rescue StandardError` its two siblings use, and for the same reason: the reconcile is
already committed, so a discovery bug must not tell an operator the library failed to index.

**The ordering is a correctness constraint, not a convenience,** twice over:

- **After the reconcile**, because discovery reads names and parentage and a path the Scanner has not
  settled is a wrong answer.
- **Before the project intake**, because a discovered project's loose files must be filed in the same
  pass. Otherwise they sit at `Projects/new-thing/`, where the seeded `*` shelf makes `Projects` the
  nearest shelf and the entire `new-thing` folder becomes **one model** — and nothing reaps an auto
  model, so the wrong row is permanent. This is the `IntakeOrderTest` hazard from the model-catalog
  arc, one step earlier in the chain.

### `config/recurring.yml`

```yaml
project_discovery:
  command: "Maker::ProjectDiscoveryJob.sweep_all!"
  schedule: every 15 minutes
```

`command:` rather than `class:`, matching every other gated entry, because the backend gate lives in
a class method. Fifteen minutes matches its neighbours; on `chunk_remote` it is the only latency
bound discovery gets, and — per `project_folder_intake`'s own comment — that number is an arbitrary
choice there rather than a floor inherited from a poll.

### `lib/tasks/projects.rake`

`projects:discover`, mirroring `models:catalog`. `projects:organize` is left alone: it calls
`Maker::ProjectIntake.for_user` directly and its job is filing, not minting.

### The cap

`MAX_PROJECTS = 50`, overridable with `PROJECT_DISCOVERY_MAX`.

**Absolute, not a percentage** — the intended first run adopts 100% of what is there, so a
percentage would be guarding against success (`Maker::ProjectIntake::MAX_MOVES` argues this at
length).

**A bad override falls back rather than crashing the job.** `Integer("-5")` *succeeds*, so a rescue
never sees a negative — it reaches `todo.first(-5)` and raises `ArgumentError: negative array size`
deep inside a recurring job, far from the typo. Zero is refused for the same reason: it discovers
nothing, forever, silently. Both fall back to the default.

**One cap, not two.** `Maker::ProjectIntake` carries `EAGER_MAX_MOVES` beside `MAX_MOVES` only
because it has an entry point inside a browser request. Nothing here does — the web doors' eager
nudge calls `Maker::ProjectIntake.for_node` directly and never routes through a job, so no discovery
ever runs in-request. **Whoever adds a nudge owes the second cap.**

---

## 5. What is deliberately not built

**No migration.** Archiving is the dismissal and `folder_node_id` is the claim, so `maker_projects`
needs no `origin`, no `auto_node_id`, no `dismissed_at`. `Maker::Model` needs `auto_node_id`
separately from `folder_node_id` because an import writes the latter; a project has exactly one
folder pointer and exactly one writer of it (`#ensure_library_folder!`, via `update_column`),
verified by grep.

**No unique index on `(user_id, folder_node_id)`.** It would be the natural safety net, and **it
would fail to apply on a live database.** Two projects can already share a folder: give project A
slug `x` (folder minted at `Projects/x`), rename A to `y` — `folder_node_id` still points at
`Projects/x` — then create a new project with slug `x`, whose `ensure_library_folder!` finds and
adopts that same node. Discovery tolerates the state; it does not fix it.

**No "adopt only non-empty folders" rule and no first-run watermark.** The rule is stateless:
position is the marker, exactly as §14f states for the filing sweep. An empty folder becomes an
empty project, which is archivable.

**No UI change.** A discovered project is an ordinary project. No badge, no separate list.

---

## 6. Consequences, stated rather than fixed

1. **`V1::Maker::ProjectsController#destroy` hard-deletes.** If the folder still exists, the next
   sweep re-adds the project. This is the price of archiving-as-dismissal, and it is the exact shape
   `docs/invariants/model-intake.md` names ("DELETING AN AUTO MODEL DISMISSES IT; DESTROYING IT
   MAKES THE SWEEP RECREATE IT"). The web UI is unaffected — `ProjectsController#destroy` already
   archives. Closing it means changing a shipped API endpoint's semantics, which is a separate
   decision.
2. **On `chunk_remote`, `model_catalog_intake` can still run before `project_folder_intake`** and
   mint a model for a whole project folder. **Pre-existing** — it happens today for any folder
   pushed under `Projects/` by a device — and self-healing in appearance: once filing moves the
   files under `Projects/*/models`, the stale row holds no attachments, the index drops empty auto
   models, and `Maker::AttachmentReaper` ages it out. Discovery widens the window slightly; it does
   not create it.
3. **Adopting a folder reorganizes it.** The moment `folder_node_id` is set, `Maker::ProjectIntake`
   files its loose root files into `models/`, `images/`, `cad/`… This is intended. It is bounded by
   `MAX_MOVES = 500`, which refuses loudly rather than half-filing. **A folder that is a git working
   tree is safe** — `Maker::AttachToProject#refusal_for`'s `:in_working_tree` attaches the rows and
   leaves the bytes alone.

---

## 7. Testing

`test/services/maker/project_discovery_test.rb` plus additions to `test/jobs/library/scan_job_test.rb`
and the project/job suites. Every guard below is **mutation-checked** — break the thing it guards,
confirm RED, restore (§15).

| # | Assertion | Mutation that must go RED |
|---|---|---|
| 1 | An archived project still claims its folder | add `.where(archived_at: nil)` to the claim lookup → the dismissed project returns |
| 2 | Dot-folders are skipped | drop the filter → `.git` becomes a project titled `.git` |
| 3 | Direct children only | drop the `parent_node_id` scope → `Projects/a/b` is adopted |
| 4 | Colliding names both adopt | stop passing `slug:` at step 6, letting `#ensure_slug` derive it → `RecordInvalid` on the second |
| 5 | Non-Latin name adopts as `project` | drop the blank fallback → `RecordInvalid` |
| 6 | The port is never touched | assert the dir-node count is unchanged; absent `Projects` root creates nothing and mkdirs nothing |
| 7 | Cap is deterministic; bad ENV falls back | `PROJECT_DISCOVERY_MAX=-5` must not raise `negative array size` |
| 8 | **ScanJob order** | swap `discover_projects` and `intake_project_folders` → a folder with a loose `panel.stl` is no longer adopted *and* filed in one `perform` |
| 9 | The chain is conditional | fires only when `created > 0`; must not fire on a scannable backend |

**Two non-vacuity checks**, because this repo's dominant failure mode is a green suite over
something that never worked:

- Test 6 must assert the candidate set was **non-empty** before trusting "nothing was created" — a
  guard that scans a set can be silently retired by that set becoming empty (§14e, the two
  architecture guards that passed over `[]` after the extraction).
- Test 8 must assert the discovery step was **invoked**, not skip when it wasn't — skip-on-the-thing-
  you-assert is how the boot guard reported success while testing nothing.

Backend legs: discovery is DB-only, so `test`, `test-s3` and `test-chunk-remote` must report
identical run counts.

---

## 8. Files

**New**
- `app/services/maker/project_discovery.rb`
- `app/jobs/maker/project_discovery_job.rb`
- `test/services/maker/project_discovery_test.rb`
- `test/jobs/maker/project_discovery_job_test.rb`

**Changed**
- `app/models/maker/project.rb` — `.slugify`, `.available_slug`; `#ensure_slug` reuses `.slugify`
- `app/services/maker/project_folders.rb` — `ROOT`
- `app/services/maker/project_intake.rb` — read `ROOT`; `#place` resolves under the project's folder
  node (§3c); `#live_folder` memoized
- `test/services/maker/project_intake_test.rb` — the §3c fix
- `app/jobs/library/scan_job.rb` — `#discover_projects`, before `#intake_project_folders`
- `config/recurring.yml` — `project_discovery`
- `lib/tasks/projects.rake` — `projects:discover`
- `test/jobs/library/scan_job_test.rb` — ordering
- `docs/STATUS.md` — the arc entry, in this branch and this PR (§15)

**Docs — §14f moves to an area file, and the ceiling forces the choice.** CLAUDE.md is **1,487
lines against a 1,500-line ceiling** (`test/docs_hygiene_test.rb`, `MAX_LINES`), so there is no room
to add discovery's rules inline, and the ceiling is a **ratchet** — lowering it as the file shrinks
is the rule, arguing to raise it is a review conversation. §14f ("Project-folder intake") is
**143 lines** binding on exactly one subsystem, which is the documented profile for an area file.

So: move §14f wholesale to **`docs/invariants/project-intake.md`**, leave a stub under the §14f
anchor naming the paths that trigger it, and add the discovery rules to that file. This is the same
move §14c/g/h/i/k already made and it is **not a demotion** — the rules are loaded when they apply
instead of skimmed on every unrelated session.

**Keep the §14f anchor.** Code cites sections by number and a citation resolving to nothing is worse
than a long file. Measured 2026-08-26 (`grep -rl '§14f' app/ lib/ test/`): **16 references across 10
files under `app/`**, plus **10 test files**, plus `docs/invariants/model-intake.md`,
`docs/invariants/addons.md` and CLAUDE.md §12.10 — which cites it as "the three things not to undo
are in §14f". Not just the four services you would guess: `Library::ReservedNames`,
`FilesController`, `ModelsController` and both addon controllers cite it too.
`test/docs_hygiene_test.rb` fails if a stub loses its file or a file loses its stub — and the
ceiling should be **ratcheted down** in the same commit, not left at 1,500.

The new rules that belong in that file:

- Discovery is **stateless — position is the marker**, the same rule the filing sweep already states
  one heading up. There is no watermark and no "handled" column.
- The claim lookup is **unscoped**; an archived project still claims its folder, and that is the
  entire dismissal mechanism.
- It **never mints `Projects/`** and never calls `ensure_library_folder!`.
- **Direct children only**, and **dot-folders are skipped** — `.git` keeps its node (§14b), so
  without the rule a working tree at the `Projects/` root becomes a project named `.git`.
- **Discovery runs strictly before the filing sweep**, and the order changes the *answer*: a
  discovered project's loose files left at its root make the whole folder one model under the seeded
  `*` shelf, permanently.
- **One cap, not two** — nothing in a browser request discovers; whoever adds a nudge owes the
  second cap.
