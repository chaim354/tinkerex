# Making the engine optional, then Stage 4

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** a maker app that runs with **no sync engine in its process** — first for share/s3
(Arc A), then for chunk against a *remote* sync server (Arc B / Stage 4).

**Why in this order.** Arc B needs Arc A. `FileLayer::ChunkRemote` talks to a sync server over
HTTP; a maker app in that mode has no more business loading the engine than a share deployment
does. Doing Stage 4 first would mean building the remote adapter while the engine is still
mandatory in-process — proving nothing about separability and leaving the same work to do after.

**Honest statement of Arc A's standalone value.** It does *not* shrink the image (the gem is
still installed, just not required), and it does *not* drop the eight tables (`db/migrate/` still
creates them — CLAUDE.md §14j, never rewritten). What it buys is that "the engine is optional" is
**executed rather than asserted**, which is the precondition for Stage 4 and for selling the
engine standalone. If that argument stops holding, stop doing this.

---

## Arc A — the engine becomes optional

### The ten host references (measured, not assumed)

| Site | Refs | Why it breaks without the engine |
|---|---|---|
| `app/models/user.rb` | 7 | `has_many class_name: "Sync::X"` — lazy, BUT `dependent: :destroy` constantizes on destroy |
| `config/recurring.yml` | 3 | `class: Sync::RetentionJob` etc. — Solid Queue resolves the constant |
| `config/initializers/postgres_pooler_check.rb` | 3 | names `Sync::PostgresPoolerCheck` |
| `config/initializers/sync_capabilities.rb` | 2 | wires `Sync.capability_check` |
| `config/initializers/sync_hooks.rb` | 1 | `Sync::Hooks.on_commit_finalized` |
| `config/routes.rb` | 1 | `Sync.draw_v1_routes(self)` |
| `app/controllers/dev_blobs_controller.rb` | 2 | dev-only, names `Storage::` |

### THE TEST-COUNT PROBLEM, AND WHY A FOURTH LEG IS THE ANSWER

CLAUDE.md §15: the three test legs must report **identical** counts, because a divergence means a
test depends on the ambient `LIBRARY_BACKEND`. Once share/s3 stop loading the engine, engine tests
genuinely cannot run there, and the counts diverge *legitimately* — which would retire a real
guard to accommodate a real change.

Two wrong answers, both rejected:
- **Keep the engine loaded in test, conditional only in production.** Then the no-engine path is
  never executed by any test — CLAUDE.md §14a's recorded bug verbatim (a boot guard that passed
  the whole suite and took production down).
- **Let the counts diverge.** That deletes the guard that catches ambient-backend leakage, to
  cover one case where divergence is expected.

**The answer:** the three existing legs keep `LIBRARY_BACKEND` set AND the engine loaded, so they
stay identical and the guard survives untouched. A **fourth leg** boots share with the engine
genuinely absent and runs a small, explicit boot-smoke suite. Divergence is then not a weakened
rule but a different suite with its own contract.

### Tasks

- [ ] **A1. `Gemfile`: `require: false`, and one conditional require.** The gem stays in the
  Gemfile and the lock unconditionally — a conditional `gem` line makes `Gemfile.lock`
  environment-dependent, which `BUNDLE_DEPLOYMENT=1` rejects outright. Load it in
  `config/application.rb` behind `TinkerexSync.wanted?(ENV)`, before `Bundler.require` finishes,
  or `Rails::Engine`'s self-registration is too late to hook.
- [ ] **A2. One predicate, one definition.** `Sync.engine_present?` already exists in the gem —
  which is useless when the gem is not loaded. The host needs its own, and it must be the SAME
  question: add `LibraryBackend.engine_wanted?` reading `LIBRARY_BACKEND`, and have the gem's
  copy defer to it when present. Two predicates that can disagree is the failure this repo keeps
  recording.
- [ ] **A3. Guard the four initializers + routes.** Each becomes a no-op when the engine is
  absent. `postgres_pooler_check` is already engine-gated *internally* — the constant reference
  itself is what fails, so the guard goes at the top.
- [ ] **A4. `recurring.yml`: `class:` → `command:` for the three engine jobs.** Solid Queue reads
  ONE file with no merge mechanism (§14j), so it cannot be made conditional. Follow the existing
  `Library::ScanJob.scan_all!` precedent — a `command:` whose gate lives in a class method.
- [ ] **A5. `user.rb`: the seven associations.** `class_name:` is lazy, but `dependent: :destroy`
  constantizes on destroy. **Probe this before choosing a fix** — do not assume laziness saves it.
- [ ] **A6. The fourth CI leg + boot-smoke suite.** Boot share with the engine absent; assert the
  app boots, `/files` renders, an upload round-trips, `Sync` is **not defined**, and the v1 sync
  routes are absent. Mutation-check by loading the engine anyway and confirming it goes red.
- [ ] **A7. CLAUDE.md §14j + STATUS.md**, same branch, same PR (§15).

---

## Arc B — Stage 4

Design: `docs/superpowers/specs/2026-08-20-chunk-repo-separation-design.md` §6.

**Not an adapter — a sync client.** The design's own words: the maker app "pulls changelog deltas
and applies them to its own `nodes`, exactly as `apply_remote` does in Rust." So Stage 4 is three
builds, not one: `FileLayer::ChunkRemote` (13 verbs over HTTP), a **Ruby changelog-apply loop**,
and a standalone host for the engine with its own `User`/`Node`/database.

**Zero new sync-server endpoints** — every verb already has one (design §6).

Sized honestly: this is an arc on the scale of Stage 3 (four PRs, a full day), and it does not
start until Arc A is green.
