# A CodeMirror source viewer, and making the library safe for git repos

**Date:** 2026-08-25
**Branch:** `claude/codemirror-code-editor-629b04`
**Status:** design approved, not yet implemented
**Origin:** "should we use codemirror to implement a lightweight code editor and viewer for those
types of files" → widened by the user to "I want to add support for full git projects that combine
code with hardware and making".

## The answer to the question as asked

**Yes, CodeMirror 6 — but the license was never the question and the editor is the small half.**
CM6 is MIT throughout (verified below), so §9 is satisfied without an argument. What costs
something is packaging it into a repo with no node build, and what actually blocks "git projects"
is that **the library currently damages a repo you put in it**.

So this design has four pieces, and the viewer is the third:

1. Repos survive contact with the library (`.git` skip + the intake shredder fix).
2. Source code enters the one file-type vocabulary.
3. The CodeMirror viewer, read-only.
4. **Editing and save-back — deferred**, by decision, to a later arc.

## Decisions taken during brainstorming

| Question | Answer | Consequence |
|---|---|---|
| Where does a repo live? | **In the library as plain files; remotes later.** | No git binary, no credentials, no storage plane outside `FileLayer`. Git-the-tool stays on the user's machine, where the folder is already mounted or synced. |
| Edit in arc 1? | **No — view-only first.** | Zero writes, so all three backends behave identically because nothing is written. Arc 2 reuses the same component. |
| Which library? | **CodeMirror 6, one pre-built bundle.** | Not thrown away when editing lands, unlike highlight.js. |
| How many languages? | **Broad.** | Measured at +160 KB minified over the minimal set — the cheap choice, see below. |

---

## Measured, not estimated

Built with `esbuild --bundle --format=esm --minify --target=es2020`, CodeMirror 6 as of
2026-08-25, in a scratch directory (nothing installed into this repo).

| bundle | minified | gzipped |
|---|---|---|
| core only (view + state + basicSetup + StreamLanguage) | 385.4 KB | 124.8 KB |
| minimal (cpp, python, json, markdown) | 751.6 KB | 257.5 KB |
| maker-focused (+ javascript, yaml, xml) | 777.9 KB | 267.5 KB |
| **broad — the chosen set** | **911.9 KB** | **317.0 KB** |

Marginal cost per language, measured on top of core:

```
lang-markdown  +217.1 KB      lang-rust        + 93.3 KB      lang-yaml       + 43.4 KB
lang-html      +173.2 KB      lang-python      + 72.9 KB      lang-xml        + 38.4 KB
lang-cpp       +125.7 KB      lang-go          + 59.0 KB      lang-json       + 26.4 KB
lang-javascript+113.8 KB      lang-sql         + 55.8 KB      legacy/shell    +  0.4 KB
lang-css       + 52.3 KB      legacy/toml      + -1.0 KB      legacy/simple-mode + 0.1 KB
```

**Two things follow from this table and both shape the design.**

The twelve `lang-*` packages sum to **1071 KB measured individually but only 527 KB together**
(912 − 385), because markdown/html/css/javascript share lezer parsers. Bundling them together is
*cheaper* than shipping them apart — which is the size argument for one bundle, independent of the
correctness argument below.

**Legacy stream modes are free** (+0.4, −1.0, +0.1 KB — the negative is minifier noise). Confirmed
by listing `@codemirror/legacy-modes/mode/`: there is **no g-code mode and no OpenSCAD mode**
upstream, but `simple-mode` is there, and a `simpleMode` definition for each costs approximately
nothing.

**Licenses**, read from the installed `package.json` of each: `codemirror`, `@codemirror/state`,
`@codemirror/view`, `@codemirror/language`, `@codemirror/lang-cpp`, `@codemirror/legacy-modes`,
`@lezer/common`, `@lezer/highlight` — **MIT, all of them.**

For scale, this repo already ships `vendor/javascript/three.core.js` at 1409 KB and
`three.module.js` at 634 KB, both dynamic-imported. A 912 KB minified CM bundle is inside existing
precedent, not a new category of weight.

---

## Piece 1 — Repos survive contact with the library

### 1a. The intake sweep is a repo shredder, today, with no editor involved

`Maker::AttachToProject#refusal_for` has exactly three rules (`:not_a_file`, `:model_bundle`,
`:attached_elsewhere`, `app/services/maker/attach_to_project.rb:179`) and none of them knows what a
working tree is. §14f's root-is-inbox rule means a repo cloned at `Projects/<slug>/` has its
**root-level files filed away by category**, unattended, on the sweep: `README.md` → `docs/`,
`main.py` → `other/`, `platformio.ini` → `other/`. Git sees a delete plus an untracked add for each
one. Nested subdirectories survive, because intake never revisits a file already in a subfolder —
but a repo's root-level files are most of what identifies it.

**Fix: a fourth refusal, `:in_working_tree`.** A directory containing `.git` is never an inbox.
Detection is a plain query — does an ancestor directory have a live child named `.git` of kind dir —
which is exactly why §1b keeps that node rather than skipping it.

**It goes in `refusal_for` UNSCOPED, and that is a deliberate difference from `:attached_elsewhere`.**
A refusal there does not mean "refuse the attachment"; `#call` returns
`relocation: (move(node) if refusal.nil?)` (`attach_to_project.rb:127`), so it means **attach the
row, leave the bytes where they are** — which is the correct answer for a file inside a repo. Read
across all four callers of `refusal_for`:

| caller | effect of the refusal | right? |
|---|---|---|
| `AttachToProject#call` | attaches the file to the project, does not move it out of the tree | yes |
| `AttachToProject#relocate` | the "Move it in as …" button declines | yes — never yank a tracked file |
| `MoveConflicts` (`move_conflicts.rb:91`) | the move is not offered in the first place | yes |
| `ProjectIntake#place` | the sweep leaves it alone | yes — this is the shredder fix |

`:attached_elsewhere` needed a `within_own_folder:` kwarg because its stated reason is positional
and stopped applying to one caller. Nothing analogous is true here: "do not move a file out from
under git" holds for every caller. **Do not scope it.**

This is a live bug with or without the rest of this design, and it is small. **Land it first, on
its own.** Everything after it is additive; this one is a stop-the-bleeding change.

### 1b. `.git`'s CONTENTS become a skipped region — and the migration is the dangerous step

Dot-directories are **not** skipped today. `Library::Scanner` skips exactly `.trash`
(root-anchored), `.maker-tmp-*` (any depth) and the `Library::OsClutter` list
(`app/services/library/scanner.rb:187`). `.git` is on none of them, so every loose object and pack
file in a repo becomes a library node with a preview enqueue behind it.

**SKIP THE SUBTREE, KEEP THE MARKER.** The `.git` **directory node is observed and indexed**; the
observers refuse to **descend** into it. This is not the shape `TRASH_PREFIX` uses (which skips the
entry itself and never looks), and the difference is load-bearing in three ways:

- **`:in_working_tree` has something to ask.** Skipping `.git` outright would delete the only
  evidence that a directory *is* a working tree, leaving Piece 1a's refusal with nothing to detect.
  With the marker kept, the question is a plain query: does this directory have a live child named
  `.git` of kind dir?
- **It dissolves the backend asymmetry.** On `chunk_remote` the `nodes` table mirrors the sync
  server's tree and the desktop client syncs `.git` whether we like it or not (§14j — what that
  server indexes is another repo's decision). A marker that exists on all three backends makes the
  working-tree question answerable uniformly, instead of one condition having two answers (§14a).
- **No ghost.** The one node we keep is genuinely observed, so it pairs normally. The contents are
  neither observed nor writable, which is the pairing the next paragraph requires.

**A new predicate, `Library::RepoMetadata` — deliberately NOT an addition to `OsClutter`.** That
module's header states its scope is macOS clutter *on purpose*, and that widening it is "a decision
to make explicitly, not a net to widen on a hunch." A repo is not clutter. But `RepoMetadata` obeys
the law `OsClutter` spells out — **one predicate, consulted from both sides** — with five consult
sites:

| site | why |
|---|---|
| `Library::Scanner` walk | index the `.git` dir node, do not descend |
| `Library::S3Observer` key filter | index a `.git/` marker, drop keys beneath it |
| `FileLayer::Share#observable!` | refuse any destination **inside** `.git` |
| `FileLayer::S3#observable!` | same |
| `Library::ReservedNames` | the door-side half; composed from the constants, never a second copy of the string |

Note the asymmetry inside the predicate itself, which is the whole subtlety: the **dir node** is a
legitimate observation and stays indexed (git writes into it through the user's own filesystem,
never through us, so this app has no reason to write there either), while **everything beneath it**
is unobservable and therefore must be
an unwritable destination. `OsClutter`'s header records why that pairing is mandatory: letting a
write path create a live node at a skipped path manufactures a ghost the Reconciler can never pair,
whose tombstone then trips the mass-deletion guard and **refuses that scan and every scan after it,
permanently**. Four separate wedges were shipped this way.

**The Files UI hides the `.git` node on all three backends.** Indexed is not the same as displayed;
nobody browsing a project wants a `.git` tile.

**The migration gate.** The mass-deletion guard is a percentage of the observable library with **no
floor** (`app/services/library/reconciler.rb:206`), raising `Library::Scanner::UnsafeScan` and
refusing the scan until `LIBRARY_SCAN_MAX_DELETE_PCT` is overridden. So for any library that
already has a `.git` indexed, the first scan after the skip lands sees every one of those nodes
vanish at once: 5,000 objects in a 6,000-file library is **83% doomed → permanently refused
scans**, which is precisely the wedge this repo has hit four times.

Therefore a rake task removes the nodes **beneath** `.git` explicitly — keeping the `.git` dir node
itself, which is the marker — **before** the skip takes effect. It:

- destroys rather than tombstones (these will never be observed again, so a tombstone would linger
  as a revivable row for a file that cannot come back — and §14a's two-tombstone-kinds rule means a
  lingering trash-kind row is worse than none);
- **refuses to touch any node carrying a `maker_file_attachments` row**, reporting it instead. A
  user attaching something out of `.git` is vanishingly unlikely, but destroying an attached node
  silently orphans a project reference, which is this repo's signature silent failure;
- is exercised against a fixture library containing a real repo, asserting the subsequent scan does
  **not** raise `UnsafeScan`.

---

## Piece 2 — Source code enters the one vocabulary

A `code` role in `Maker::FileAttachment::ROLE_BY_EXT` → a `code` folder in
`Maker::ProjectFolders::ROLE_FOLDERS`. That `fetch` has no default and raises `KeyError` on an
unmapped role, and `project_folders_test.rb`'s totality test is what forces the folder decision to
be made rather than discovered in production.

Every extension must satisfy `FilesController::EXT_RE` (`/\A[a-z0-9]{1,8}\z/`,
`app/controllers/files_controller.rb:899`) or it renders a filter chip that links and silently does
nothing. Checked: `ino`, `cpp`, `hpp`, `cc`, `py`, `rs`, `go`, `ts`, `toml`, `yml`, `cmake`, `sh`
all fit.

### The second vocabulary that has to go

`FilesController#preview_kind` (`files_controller.rb:1130`) already returns `:text` for
`txt md markdown csv json xml yml yaml log rb js ts py rs go c h cpp html css toml ini cfg conf sh
gcode`. That is a **second extension table sitting beside `ROLE_BY_EXT`** — exactly the drift §14d
says must not exist, and exactly what `FilesHelper::EXT_FAMILIES` was rewritten to end in
2026-07-29 after two lists disagreed about `.svg` for months.

We are about to add ~15 extensions to both. **Derive the text set from the one table instead of
extending the inline array.** This is a targeted fix inside code the change already touches, not an
unrelated refactor — and doing the opposite (adding fifteen extensions to a duplicate list) would
be knowingly deepening a defect §14d names.

Note the existing list already contains `ini cfg conf`, which have no CM language; the `properties`
legacy mode covers them, or they fall back to plain text. Either is fine and the fallback is the
default.

---

## Piece 3 — The viewer

**One Stimulus controller, `codeview`**, replacing `textpreview` on the `:text` branch of
`app/views/files/show.html.erb:121`. Because `preview_kind` already routes source files to `:text`,
this is a **drop-in on an existing branch**: same fetch, same `blob_file_path` URL, same truncation
contract. The bytes path does not change, so nothing about `Delivery`, presigning or §15 is touched.

**Loading.** `await import()` of the bundle happens *after* the fetch resolves, so a page with no
text file never downloads it — the discipline `modelviewer_controller.js` already applies to
Three.js.

**Read-only is a state fact, not a CSS fact.** `EditorState.readOnly.of(true)` **and**
`EditorView.editable.of(false)`. Both: the first refuses document changes, the second removes the
caret and IME. A contenteditable that merely looks disabled is a bug waiting for someone's
keyboard.

**Language dispatch** is one ext→language table in JS, defaulting to *no language* (line numbers,
no highlighting) rather than guessing. `gcode` and `scad` get `simpleMode` definitions of our own,
measured free.

**`markdown` is worth a note, not a change.** It is the single heaviest grammar (+217 KB) and for
*viewing* a `.md` file a rendered view would arguably serve better than a source view. Out of scope
here — the app already treats `.md` as text and this design does not change which branch it lands
on — but recorded so the question is asked deliberately later rather than rediscovered.

### The bundle, and the one rule that must be written down

One file, `vendor/javascript/codemirror.js`, built by `npx esbuild` from a committed entry file with
pinned versions, plus a `bin/` script that reproduces it byte-for-byte. This **differs from every
other entry in `vendor/javascript/`**, which are unmodified upstream bytes fetched from a CDN — so
the reproduction script and a header comment naming the exact command are the price of the
difference, and the spec says so rather than leaving a future reader to wonder where the file came
from.

**NEVER `bin/importmap pin @codemirror/*` per package.** Two reasons, and the second is the one
that bites:

1. It is the jspm-splits-into-a-dangling-`../_/`-chunk failure `config/importmap.rb` already
   documents twice at length (JSZip, Three.js).
2. **Two copies of `@codemirror/state` break CM6 silently.** Facets and `StateField`s have object
   identity; a second copy makes extensions no-op with no error and no console warning. That is
   this repo's dominant failure shape — a green everything over something that never worked — and
   it earns a §14 line, not a comment in a JS file.

---

## Piece 4 — Editing (deferred, recorded so it is not re-derived)

Nothing above forecloses it. When it lands: the same component drops the two read-only facets and
gains a save path that must branch on `port_writable?` — a port `write(..., replace: true)` on
share/s3, the two-phase `begin_upload`/`put_chunk`/`finalize_upload` on chunk_remote — and **must
reuse the existing `node_id`**, per §14a. A replace written as delete-then-create passes any
bytes-oriented test while silently orphaning every attachment, BOM link and tag on that file.

The open product question it will have to answer: whether saving a file that sits **inside a
working tree** is allowed at all, or refused on the grounds that the app must never write a file out
from under a tree the user has staged or is mid-rebase on.

---

## Order of work

1. **`:in_working_tree` refusal.** Standalone, small, fixes a live bug.
2. **`Library::RepoMetadata` + the five consult sites + the migration rake task.** The risky one.
3. **The `code` role, and deriving the text set from the one table.**
4. **The bundle, its build script, and the importmap guard.**
5. **The `codeview` controller and the `gcode`/`scad` stream modes.**

Steps 1–3 are worth landing before 4–5 even if the viewer slips: they are what makes the library
safe for a repo, which is the actual ask.

## Guards

Every one mutation-checked per §15 — written, seen green, then the guarded thing broken to confirm
**red**, then restored.

- **No per-package `@codemirror/*` pins in `config/importmap.rb`**, in the `ci_hygiene_test.rb`
  style. The failure it guards is silent, so a comment cannot carry it. The guard must assert it
  actually **scanned** the importmap — §14e: "a guard that scans a directory dies silently when the
  directory leaves," and its sibling, "assert the scanned set is non-empty before trusting what it
  reports."
- **`Library::RepoMetadata` parity** — asserted consulted at all five sites, mutated by removing one
  call site and confirming red. This is the `OsClutter` law and the guard is what keeps the two
  sides from drifting.
- **The intake refusal** — a fixture repo at a project root, swept, asserting nothing moved;
  mutated by deleting the refusal and confirming the shred reappears.
- **The migration task** — fixture library with an indexed `.git`, task runs, subsequent scan
  asserted **not** to raise `UnsafeScan`; plus an attached-node case asserted reported-and-skipped
  rather than destroyed.
- **`stimulus_hygiene_test.rb`** already covers the `codeview` identifier resolving, for free — a
  `data-controller` naming nothing is a silent no-op that once left a feature inert for nine days.
- **Bundle reproducibility** — the `bin/` script re-runs and produces identical bytes.

## To verify during implementation, not assumed now

- **Does `fetch().text()` on the s3 backend work today?** That path is a redirect to a cross-origin
  presigned URL, and reading the body needs CORS on the bucket. If it is broken it is broken **now**,
  in `textpreview` — this design would inherit the bug, not cause it. Drive a real request against
  the s3 leg rather than reasoning about it.
- **What a 100 MB g-code file does.** The current 200,000-character truncation stays as the resting
  behaviour; confirm CM6's behaviour at the cap rather than assuming the cap is sufficient.
- **Whether kamal-proxy gzips the bundle.** 912 KB vs 317 KB is the whole difference and nothing in
  this repo currently asserts it either way.

## Rejected

- **highlight.js / Prism now, CodeMirror later.** One small file, no duplicate-instance trap — but
  read-only by nature, so arc 2 throws it away and does this anyway, having shipped two viewers.
- **`<pre>` plus line numbers, no dependency.** Genuinely fine for a 40-line `platformio.ini`,
  useless for 3000 lines of firmware.
- **Server-side clone, Rails runs git.** Real commits from the browser, but a whole storage plane
  outside `FileLayer` plus credentials and push permissions.
- **Linked remote, read-only via the provider API.** No bytes in the library, but needs network and
  a token, and does not work on an offline self-host box — which is deployment mode 1 (§1).
- **Adding `.git` to `Library::OsClutter`.** Semantically wrong; that module's scope is macOS
  clutter by explicit decision. Same law, separate predicate.
- **A dedicated "Code" tab with a persistent tree.** `FilesController#index` already does folder
  navigation with paging and a repo is just folders. A real tree is a want, but it is a fifth piece
  competing with 1–3 for the same arc.
