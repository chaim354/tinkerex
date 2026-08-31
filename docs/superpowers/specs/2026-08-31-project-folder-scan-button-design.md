# Per-project folder scan button — design

**Date:** 2026-08-31
**Status:** approved, ready for planning

## Problem

A maker drops six STLs into `Projects/desk-lamp/` in Finder over SMB, opens the project page,
and sees nothing. On share/s3 the files are invisible until `library_scan` polls (up to 15
minutes); on `chunk_remote` until `remote_changelog_pull` runs (up to 2 minutes) — and even then
only if they were *new arrivals*, since `ChangelogSync`'s nudge takes live file arrivals only.

There is no user-facing way to say "look now." This adds one, per project, where the files are
shown.

## The constraint that shapes everything: a scan cannot be scoped to one folder

`Library::Reconciler` compares observations against `@user.nodes.present` — the entire catalog
(`observable_live_paths` → `live_file_paths`, `app/services/library/reconciler.rb:250`). Handing
`Library::Scanner` a project subfolder as `root:` would make every file *outside* that subtree
appear in `vanished_paths`, tripping the mass-deletion guard (`UnsafeScan`) at best. `ScanJob`'s
`root:` parameter means **a share root**, not an arbitrary folder — its own header says so.

So "scan this project's folder" decomposes into two different operations:

1. **Observing the store** — inherently library-wide on share/s3; a changelog pull on chunk_remote.
2. **Filing** — `Maker::ProjectIntake.for_project(user:, project:)`, which is genuinely per-project.

Filing alone is not enough: on share/s3 the intake reads `nodes`, and files just dropped on the
NAS are not in `nodes` yet. **An intake-only button would visibly do nothing in the exact scenario
it exists for.** The button therefore does (1), and relies on the existing chains for (2).

## Design

### Route and controller

```
POST /projects/:project_id/scan  →  Projects::ScansController#create
```

`resource :scan, only: :create, module: :projects` nested under the existing `resources :projects`.
Singular resource: there is no scan record and no id.

`#create` branches on `FileLayer.current.capabilities.scannable?` — the capability, never
`is_a?(FileLayer::Share)`. §14b records that exact gate shipping as a silent bug when S3 landed.

### The two paths, and why they differ

| backend | what the button does | who files the files |
|---|---|---|
| `share` / `s3` | `Library::ScanJob.perform_later(user_id:, **root_args)` — **async** | `ScanJob#perform` already runs `discover_projects → intake_project_folders → intake_models` inline and strictly ordered |
| `chunk_remote` | `RemoteChangelogPullJob.perform_now(user_id:)` then `Maker::ProjectIntake.for_project` — **sync** | the two calls, in that order |

`root_args` reuses `ScanJob.scan_all!`'s own rule verbatim: `{ root: adapter.root.to_s }` for
Share, `{}` for S3. **A bucket plus its credentials must never be serialized into the queue's
database** — `ScanJob#perform`'s header states this, and the S3 fan-out names only the user for it.

Both jobs' `#perform` is deliberately ungated; both headers say a caller who names a user deserves
the operation rather than a silent no-op. This controller is exactly such a caller.

#### Why share/s3 must NOT also run the intake synchronously

This is the §14f race, and it is a correctness constraint, not a preference. A move made after the
Scanner has captured its observations gets paired back by `(content_hash, size)` — `best_pairing`
working as designed — repointing the node to its **old** path while the bytes sit at the new one.
In that window `library_present?` still reads true, so `Share#download`'s `ENOENT` maps to
`NotFound` and the controller renders a **terminal 404**, not the retryable 503. Running the intake
inline inside `ScanJob`, after `observer.call`, is what makes the overlap impossible. The button
must not open a second, unsequenced filer.

#### Why chunk_remote is synchronous, and why that asymmetry is correct

There is no scan on chunk_remote, so no race. A no-op pull is **one** GET (`changelog_sync_test`
pins the count at exactly one), and `ProjectIntake` is capped — so the work is bounded and belongs
in the request, where it can report real counts.

It also closes a real gap: `ChangelogSync#nudge_project_intake` fires only for **live file
arrivals**. Files already in the mirror but unfiled — a prior collision, a folder adopted by
discovery — get no nudge, so a pull-only button would find nothing to do and appear broken. The
explicit `for_project` call is what makes the button honest in that case.

**A synchronous pull here does not violate §14a.** That invariant forbids closing mirror staleness
with a pull in `FilesController#index` "or any other read path". This is a POST — an explicit user
command, not a read. The pinned journey test (a plain read asserted *not* to see a server-side
node) is unaffected.

Backend-keyed behaviour has precedent here: `EAGER_MAX_MOVES` is 25 on chunk and 5 on S3, keyed on
"one move here is three round-trips" — a property no adapter declares.

### Feedback

**chunk_remote:** the flash reports the real counts off the `Maker::ProjectIntake::Result`
that `.for_project` returns — `attached` / `moved` / `skipped`. (`Result`, not `RunResult`:
`RunResult` is what the all-users `.for_user` returns and carries the run-wide cap, which a
single-project call has no business reporting.)

The **conflict clause is not re-worded here.** `ProjectFolderIntake#project_intake_sentence(lead,
result, filename)` already owns that sentence, and its plural helper `unfiled_by_conflict(result,
names)` is the way in for a caller with a set rather than one upload: pass the names out of
`result.skips`, take the first that collided, and hand it to `project_intake_sentence` with a scan
lead-in. §14f: the doors differ on the lead-in and must not differ on what follows. A lead-in
carries **no trailing punctuation** — the conflict form turns the period into a comma.

**share/s3:** flash says a scan started, and a `scanreload` Stimulus controller reloads the page
once after **6 seconds** (a `data-scanreload-delay-value`, so the number is one place).

> **Known limitation, accepted:** the reload timer is a guess. A large NAS walk (~1–3 min per
> 100k files) will outlast it, and the reloaded page will show no new files. The flash copy is
> therefore written so that a too-early refresh reads as *still working*, not as *nothing
> happened* — it states that a large library takes longer and to reload again. A status endpoint
> to poll was considered and declined as more surface than the button itself; if the reload proves
> unsatisfying in use, that is the upgrade path.

The controller is `app/javascript/controllers/scanreload_controller.js` → identifier `scanreload`,
matching the repo's all-lowercase single-word convention (`thumbfallback`, `commitgroup`,
`modelviewer`). It is rendered **only on the async path**; chunk_remote's work is already done.
§14d: a `data-controller` name that resolves to nothing is a silent no-op, which is why
`test/stimulus_hygiene_test.rb` exists — the new file must be present for the new attribute.

### Throttle

```ruby
rate_limit to: 3, within: 1.minute, by: -> { current_user.id },
           with: -> { redirect_to project_path(@project),
                      alert: "A scan for this library just started — give it a moment." }
```

Keyed by **user**, not the default `request.remote_ip`. This is not only abuse control: `ScanJob`'s
`limits_concurrency ... on_conflict: :discard` means a second click during a running scan is
**silently dropped**, so without a throttle the user gets "Scanning…" and nothing happens. The
throttle turns that into an honest message.

Counts in `config.action_controller.cache_store`; the test env already sets `:memory_store` for
this (§14e — `NullStore#increment` returns nil, so a throttle backed by the default test store
fires never and its test passes for the wrong reason). Tests must clear the store per test.

### Button placement

Files panel head, beside "Attach existing" (`app/views/projects/_attachments.html.erb`), inside the
existing `.panel-actions` div — the surface that shows the folder's contents.

### No library folder yet

The button renders and works. The library refresh is still useful; `ProjectIntake` returns
`status: :no_folder` and files nothing. **It must not call `ensure_library_folder!`** — §14f states
this twice, and `Projects::AttachmentsController#relocate` shipped exactly that bug (an endpoint
minting `Projects/<slug>` as a side effect of being POSTed to).

## Testing

- **Request test per backend leg.** The three legs (`test`, `test-s3`, `test-chunk-remote`) must
  report identical run counts, so the test branches on capability rather than being skipped on two
  of three.
- **share/s3:** asserts `Library::ScanJob` enqueued with the right args — including that the **s3
  case carries no `root:`** (the credentials-in-the-queue rule), and that `Maker::ProjectIntake` is
  **not** called synchronously (the §14f race).
- **chunk_remote:** asserts the pull ran and the intake ran, **in that order** (a filing pass
  before the pull would report on a stale mirror), and that the flash carries the real counts.
  One case asserts the shared conflict clause is produced via `project_intake_sentence`, not a
  paraphrase.
- **Rendered markup, not a hash.** Assert the button's actual `formaction`/path and the
  `data-controller="scanreload"` attribute in the response body. §14d: a `form_with` missing
  `scope:` emits param names the controller rejects, and a test POSTing a Ruby hash bypasses the
  form entirely and cannot see it.
- **Mutation-check the throttle** (§15): confirm it goes red when the `rate_limit` line is removed.
  Also mutation-check the no-sync-intake assertion on share/s3 by adding the forbidden call.
- **`stimulus_hygiene_test`** covers the new `data-controller` automatically — no test edit needed,
  but it is the guard that the new JS file exists.

## Explicitly out of scope

- A status endpoint or progress polling (declined above).
- Scoping a store scan to one folder — impossible without reworking `Library::Reconciler`'s
  comparison scope, which is far beyond a button.
- Any change to `Library::Reconciler`, `Library::Scanner`, `ChangelogSync`, or the ScanJob
  sequencing. The button is a new caller of existing, unmodified machinery.
- A `/tools` addon surface, or a v1 API endpoint. Web only.
