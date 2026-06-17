# Plan: New-User Onboarding Flow

**Date:** 2026-06-16 · **Status:** PLAN / RESEARCH (no code) · **Scope:** first-run +
getting-started experience for both the **Tauri desktop app** (`client/maker-app`) and the
**web UI** (Rails `app/views`). Covers the file/sync layer *and* the maker product layer
(Projects / Inventory / BOM / preview).

> **Goal (one sentence):** a brand-new user, on a fresh install, reaches their first
> "this is mine and it works" moment — a real file synced **and** a project visible —
> in **under 5 minutes**, without reading docs.

This is an actionable plan, not a manifesto. It says *what* the flow is, *where* each piece
lives in the codebase, and *how* we measure that it worked.

---

## 0. Why this matters (the stakes)

SaaS products lose up to **75% of new users in the first week** without effective onboarding;
a setup checklist plus a clear first action measurably moves completion and 30-day retention
(Notion's setup checklist drove onboarding completion to ~60% with a ~40% retention bump at
30 days). [ProductLed][1] [Candu/Notion][6] Our product is *harder* to onboard than a typical
SaaS because the first run involves **three moving parts most apps don't have**: a server
(self-hosted or managed), a **native mount** (FUSE/CfAPI/WebDAV per OS), and **multi-device
pairing**. The onboarding has to hide that machinery, not expose it.

The current state (what a new user hits today):

- **Tauri app** (`client/maker-app/src/index.html`): drops the user straight onto a raw
  "Sign in to sync" form — four fields (server URL, email, password, **mount point**),
  prefilled with developer defaults (`http://localhost:3001`, `maker@example.com`,
  `/tmp/MakerDrive`). No account creation, no concept explanation, no "what do I do next."
  The Library view's only empty state is *"No items yet. Click 'New item' to add one."*
- **Web UI** (`app/views/files`, `app/views/users`): Devise-style auth screens +
  a file browser. No first-run guidance, no checklist, no sample data.

Neither surface teaches the **core loop**. That's the gap this plan closes.

---

## 1. What the research says (best practices, cited)

Synthesis of first-run/onboarding patterns from comparable tools and PLG playbooks:

1. **Drive to a single activation ("aha") moment, fast.** Every step should raise the odds the
   user hits the one action that predicts retention. For Notion it's *creating/customizing a
   page*; for Dropbox it's *a file syncing across two surfaces*. [Candu/Notion][6]
   [ProductSchool][7] **For us the aha is: a file the user dropped into the mounted folder
   reappears in the app/web — and (stretch) shows a 3D preview.** That is the whole product in
   one gesture.
2. **A getting-started checklist with visible progress** raises completion. Progress
   indicators make setup feel achievable. [ProductLed][1] [Flowjam][2]
3. **Empty states are real estate, not dead ends** — give the next best action: import,
   sample data, or a template, never a blank slate. [Candu][3] Avoid *misleading* dummy data;
   prefer clearly-labeled sample data the user can delete.
4. **Progressive disclosure** — reveal complexity gradually; don't front-load every feature.
   NN/g shows it improves learnability, efficiency, and error rate. [usertourkit][4]
5. **Job/persona questionnaire up front** filters the experience (Notion asks "what are you
   here to do?" → curated templates). [Candu/Notion][6] We can ask "what do you make?"
   (3D printing / CNC / laser / electronics / mixed) to seed relevant sample data + tags.
6. **Setup wizard that's skippable** and resumable (Plex's wizard has a Skip button top-right;
   it signs you in, then helps you add libraries). [Plex][5]
7. **Two-way sync as the activation flow** (Dropbox onboards by syncing a file phone→desktop
   →phone so the user *sees* it work). [Dropbox.tech][8] Our analog: write a file into the
   mount, watch it appear in the app.
8. **First-run admin/setup for self-hosted** (Nextcloud: visit the server, create the admin
   account, real-time password-strength meter, then you're in and can upload). [Nextcloud][9]
   We need the equivalent for the **self-host** path (point the app at *my* server) vs the
   **managed** path (sign up, server is implicit).

---

## 2. The core features to surface, in order

The onboarding teaches the **core loop** and nothing else. Everything advanced
(selective sync, bandwidth controls, conflict resolution, versioning UI, locks, collections,
inventory depth) is **progressively disclosed** later, in context.

**Ideal first-run order** (each step is one screen; each builds on the last):

| # | Step | Why it's here / what it proves | Aha proximity |
|---|---|---|---|
| 0 | **Choose deployment** — *Managed* (we host) vs *Self-hosted* (my server) | Forks the whole flow; everything downstream depends on it | setup |
| 1 | **Account** — managed: sign up (email+password, strength meter); self-host: enter server URL + create/sign-in admin, or **pair** an existing library | Identity + first device enrolled | setup |
| 2 | **Pick what you make** (3D / CNC / laser / electronics / mixed) — optional, skippable | Personalizes sample data + default tags (Notion's job questionnaire) | setup |
| 3 | **Mount the drive** — pick a folder, one click; we explain "this is your synced workshop folder" with the OS-appropriate copy | The native-mount machinery, made invisible | **near** |
| 4 | **Drop your first file** (or "use a sample model") → it syncs → **appears in the app** | THE activation moment: write→sync→see | **AHA** |
| 5 | **See a preview** — the synced model renders (3D viewer) | Proves the product is more than a folder | **AHA+** |
| 6 | **Create your first Project** + attach that file + add one BOM line | Reveals the product layer = the connective tissue (the moat, per `research-maker-app-features.md`) | value |
| 7 | **Add a second device** (pairing) — optional, deferred to a checklist item | The "sync" payoff; not blocking first-run | value |

Steps 0–5 are the **first-run wizard** (target < 5 min). Steps 6–7 live in the **getting-started
checklist** so first-run stays short but the path forward is obvious.

---

## 3. The recommended flow (detailed)

### 3a. First-run wizard (Tauri desktop)

A modal/overlay wizard that appears when no device token is persisted (first launch).
Skippable (top-right "Skip setup" → drops to the current sign-in form). Resumable (state in
local config so a half-finished setup picks up where it left off).

```
┌─ Welcome to Maker ──────────────────────────────┐
│  Your workshop's files + projects, synced.       │
│                                                  │
│   ○ Use Maker Cloud (we host it)   [managed]     │
│   ○ Connect my own server          [self-host]   │
│                                       [Continue]  │
└──────────────────────────────────────────────────┘
        │ managed                    │ self-host
        ▼                            ▼
  Sign up / Sign in            Server URL ──► reachability check (ping /up)
  email + password             ──► Sign in OR "Pair this device" (existing library)
  + strength meter
        └──────────────┬─────────────┘
                       ▼
        Pick what you make (chips, skippable)
                       ▼
        Choose your synced folder  [Browse…]  (default per-OS; explain it)
                       ▼
        ⏳ Mounting…  ✓ Mounted at <path>
                       ▼
   ┌─ Add your first file ──────────────────────┐
   │  Drop a model here, or                      │
   │  [ Use a sample model ]  (a real .3mf)      │
   │  ……syncing……  ✓ "benchy.3mf" is in your    │
   │  library  →  [ preview rotating thumbnail ] │  ← AHA
   └─────────────────────────────────────────────┘
                       ▼
        🎉 You're set up. Here's what's next ▸ (checklist)
```

**Key UX rules:**

- **Hide the machinery.** The mount step never says "FUSE/CfAPI/WebDAV." It says
  "your synced folder." (The per-OS copy already exists in `main.js`'s `platform` switch —
  reuse it as a one-liner caption, not jargon.)
- **Sensible defaults, no dev junk.** Replace the prefilled `localhost:3001` /
  `maker@example.com` / `/tmp/MakerDrive` with: managed → server implicit; self-host → empty
  with a placeholder + reachability check; mount → real per-OS default (`~/Maker`,
  `%USERPROFILE%\Maker`).
- **Reachability check before sign-in** (self-host) so a typo'd URL fails *helpfully*
  ("can't reach that server — is it running?") not as a raw HTTP error.
- **The sample model is a real asset**, clearly labeled, deletable. It guarantees the aha
  even for a user who has nothing to upload yet. Ship one small permissively-licensed `.3mf`
  (e.g. a calibration cube / public-domain test model) bundled with the app.

### 3b. First-run wizard (Web)

The web UI needs a parallel — same spine, fewer steps (no native mount in the browser; the
web surface is upload/download, per CLAUDE.md §11). Web first-run:

1. **Account** (sign up / confirm — already exists in `app/views/users/registrations`).
2. **Welcome card** on first dashboard hit: "Pick what you make" + "Upload your first model
   or use a sample."
3. **Upload → preview** (the aha, browser-side; bytes go direct to storage off Rails).
4. **Checklist** card pinned on the dashboard until completed/dismissed.

The web wizard also serves the **self-host admin first-run** (Nextcloud-style): the very first
account created on a fresh server is the admin/owner; show a one-time "your server is ready"
confirmation. (Registration is already new-account-only per CLAUDE.md §8.)

### 3c. Getting-started checklist (both surfaces)

A persistent, dismissible checklist (a card in the app sidebar / web dashboard) with a
progress bar. Completing an item checks it automatically by **observing real events**, not
self-report:

- [x] Create your account
- [x] Mount your synced folder *(desktop)* / Sign in *(web)*
- [x] Add your first file
- [ ] Preview a model
- [ ] **Create your first project**
- [ ] **Add a part to inventory** *(or add a BOM line)*
- [ ] **Add a second device** *(pairing)*
- [ ] *(advanced, collapsed)* Turn on selective sync · set bandwidth limits

Each unchecked item is a button that **takes the user to that action** (deep-link into the
Library view / project create modal / pairing screen). Collapsed "advanced" section is
progressive disclosure (rule #4). Auto-dismiss the whole card once all required items are done,
but keep it reachable from a "?" menu.

### 3d. Empty states (replace dead ends with next actions)

| Surface | Today | Proposed |
|---|---|---|
| Files (app) | "No files yet. Save a file into the mounted drive…" (already decent) | Keep, but add a **[Reveal folder in Finder/Explorer]** button + **[Use a sample model]** |
| Library grid | "No items yet. Click 'New item' to add one." | "Your library is empty. **[Add your first item]** or **[Import a sample project]**" + a 1-line note that items reference your synced files |
| Collections | (none) | "Group related models into a collection — e.g. *Printer Upgrades*. **[Create one]**" |
| Tasks | (none) | "Track build steps here. **[Add your first task]**" |
| Projects (when built) | — | "A project ties your files, BOM, and build log together. **[Create a project]**" with a ghost/sample project preview |
| Preview pane | — | "Open a `.stl`/`.3mf`/`.step` to see it here." |

### 3e. Sample / demo data

- **Bundled sample model** (one small `.3mf`) — used in the wizard's "Use a sample model"
  path. Permissive license; clearly labeled `Sample - Benchy.3mf`; deletable.
- **Optional sample project** — seeded only if the user clicks "Import a sample project" in an
  empty state. A fully-wired example: a project with the sample model attached, a 2-line BOM
  referencing two sample inventory parts, and one build-log entry. Demonstrates the *graph*
  (project → versioned file → BOM → inventory) that is the product's whole thesis
  (`research-maker-app-features.md` §0). **Never auto-injected** — always opt-in and labeled
  "Sample," so it can't be mistaken for the user's real data (research rule #3).

### 3f. Progressive disclosure map (what we hide at first)

Surfaced **only in context, after the core loop is learned:**

- Conflict resolution modal (already event-driven — fine; it appears only when a conflict
  actually occurs).
- Version history / restore (a "versions" link per file — already exists; leave it, it's
  discoverable, not blocking).
- File locking indicators (already passive 🔒 badges — fine).
- Selective sync, progressive/range hydration, bandwidth controls → checklist "advanced"
  section + Settings, never first-run.
- Inventory depth (suppliers, locations, quantities) → revealed when the user opens an
  inventory item, not on first add.

---

## 4. Where each piece lives (implementation plan)

### 4a. Tauri desktop (`client/maker-app/`)

**New front-end module: `src/onboarding.js`** (vanilla ES module, same pattern as
`main.js`/`library.js`; loaded first, exposes `window.MakerOnboarding`).

- **State / gating:** on boot, ask the backend whether a device token is already persisted.
  Add a Tauri command `onboarding_state` in `src-tauri/src/lib.rs` returning
  `{ has_token: bool, deployment: "managed"|"selfhost"|null, checklist: {...} }`. Persist
  onboarding/checklist state in the app's existing local config store (same place the device
  token lives). If `!has_token` → render the wizard overlay; else → current UI.
- **Wizard markup:** add a `<div id="onboarding" class="overlay wizard">` to
  `src/index.html` with the step panels (welcome / account / persona / mount / first-file /
  done). Reuse existing CSS primitives (`.card`, `.overlay`, `.modal`, `.primary`, `.spinner`,
  toasts) from `styles.css`; add a `.wizard` + `.wizard-steps` block.
- **Account step:** managed → a new `sync_signup` command (server already supports
  registration via the auth routes) + existing `sync_login`. Self-host → reachability ping
  (new `server_reachable(serverUrl)` command hitting `/up`) before login; **pairing** path →
  new commands `pair_begin`/`pair_complete` mapping to the existing `DevicePairing` API
  (`POST /v1/devices/pairing` → `/v1/auth/pair`, CLAUDE.md §8).
- **Persona step:** store the choice locally + send as default tags when seeding; no server
  schema change required (tags already exist in the Library).
- **Mount step:** reuse the existing `sync_login(..., mountpoint)` path and the `platform`
  command's per-OS copy. Add a native folder-picker (Tauri dialog plugin) so the user
  **browses** instead of typing a path — removes the biggest friction in the current form.
- **First-file step:** "Use a sample model" copies a bundled asset
  (`src-tauri/assets/sample-benchy.3mf`, added to the Tauri bundle) into the mounted folder,
  then polls `browse` until it appears (reuse `loadFiles`). On appearance → fetch its
  preview/thumbnail (see §4c) → show it → mark the aha complete.
- **Checklist:** a dismissible card rendered in both views' sidebars; reads
  `onboarding_state.checklist`; each item deep-links via the existing `showView()` + opening
  the relevant modal in `library.js`. Auto-checks by observing: token present, mount active
  (`sync_status`), `browse` non-empty, a preview fetched, a project created
  (`GET /v1/maker/projects` non-empty), etc.

### 4b. Web (`app/`)

- **First-run gate:** a `before_action` (in `application_controller.rb` or a small
  `OnboardingConcern`) that checks a per-user `onboarding_completed_at` (new nullable column on
  `users`) and a checklist JSON column (or a small `onboarding_states` table). Redirect /
  render the welcome card until dismissed.
- **Welcome + checklist partials:** `app/views/onboarding/_welcome.html.erb` and
  `_checklist.html.erb`, rendered into the files dashboard layout (`app/views/layouts`).
- **Persona + sample:** a tiny `OnboardingController` (`app/controllers/onboarding_controller.rb`)
  with `update` (persona, dismiss) and `seed_sample` (creates the opt-in sample project via the
  existing `v1/maker` services). Route under a new `resource :onboarding`.
- **Upload→preview aha:** reuse the existing web upload path (`files_controller`) + the preview
  endpoint (`v1/maker/previews`, already routed). Empty-state copy updates live in
  `app/views/files/index.html.erb`.
- **Server config:** copy strings for managed vs self-host can key off an existing
  deployment/env flag (e.g. `MANAGED=true`) so the same views serve both hosts (CLAUDE.md §7).

### 4c. Preview dependency (the aha's second half)

Step 5 (and the Library preview) needs a **model thumbnail/preview**. The `previews` endpoint
is already routed (`resources :previews, only: %i[index create]` under `v1/maker`). For
onboarding we need *at minimum* a static thumbnail of the sample model so the aha lands even
before full server-side render jobs (FreeCAD/CadQuery, CLAUDE.md §4) exist. **Plan:** ship a
pre-rendered thumbnail for the bundled sample so step 5 is instant; for user files, fall back
to a Three.js in-browser render (already the intended browser preview path) or "preview
generating…" if the server job is async. *This is the one onboarding piece with a real upstream
dependency — flag it; if previews aren't ready, step 5 degrades to "✓ synced" and the checklist
keeps a "Preview a model" item.*

### 4d. Server (minimal)

No new sync-layer work. Additions are product-layer/config only:

- `users.onboarding_completed_at` (nullable) + checklist state (JSON column or table).
- `OnboardingController` + `seed_sample` service (composes existing `v1/maker` create paths;
  marks created records `sample: true` so they're visibly removable).
- Optional `MANAGED` env flag to switch managed/self-host copy (likely already implied by §7
  config).

---

## 5. Success metrics

Instrument the funnel (client emits events; server counts). Targets are starting hypotheses.

| Metric | Definition | Target |
|---|---|---|
| **Time to first sync (TTFS)** | wizard start → first file visible in app | **< 5 min** (P50) |
| **Activation rate** | % of new accounts that reach the aha (file synced + visible) within 24 h | **> 60%** |
| **Wizard completion** | % who finish steps 0–5 without skipping out | **> 55%** |
| **Checklist completion** | % completing all *required* checklist items in 7 days | **> 40%** |
| **First project created** | % creating ≥1 project in 7 days (product-layer adoption) | **> 35%** |
| **Second-device pairing** | % pairing a 2nd device in 14 days (sync payoff) | **> 25%** |
| **Day-1 / Day-7 retention** | returns next day / next week | track; expect lift vs no-onboarding |
| **Mount-failure rate** | % of mount attempts that error in step 3 | **< 10%** (else the OS copy/picker needs work) |

Per-step **drop-off** is the most actionable view — it pinpoints exactly which screen leaks
users (research rule: progress + per-step funnel). Self-host vs managed should be segmented
(self-host has the extra server-URL/reachability step and will drop differently).

---

## 6. Phasing (build order)

1. **Phase 1 — Desktop wizard skeleton + real defaults.** Replace dev-junk prefills; add the
   deployment fork, account step (managed signup + self-host reachability), folder picker, and
   the mount step. *Ships value immediately even without sample data.* (`onboarding.js`,
   `index.html`, `lib.rs` commands.)
2. **Phase 2 — The aha.** Bundle the sample model; wire "Use a sample model" → sync → appears;
   static thumbnail preview. (Depends on §4c.)
3. **Phase 3 — Getting-started checklist** (desktop), event-driven auto-check + deep links.
4. **Phase 4 — Web first-run** (welcome card, checklist, empty-state copy, opt-in sample
   project). Reuses Phase 1–3 decisions.
5. **Phase 5 — Pairing + project/inventory checklist items + sample-project graph** (the
   product-layer payoff; aligns with §12 step 9 maker-app work).
6. **Phase 6 — Instrumentation + iterate** on per-step drop-off.

Phases 1–3 alone fix the worst current gap (raw dev form → guided first sync). 4–5 extend it to
the web + product layer. 6 closes the loop with data.

---

## 7. Open questions / dependencies

- **Preview readiness** (§4c) — the only hard upstream dependency. Confirm whether server-side
  render or browser Three.js preview is available for the aha; degrade gracefully if not.
- **Sample model licensing** — pick a permissive/public-domain model (CLAUDE.md §9). A
  calibration cube is trivially safe.
- **Pairing UX surface** — pairing is built server-side; the desktop needs commands wired
  (§4a). Keep it *off* the critical first-run path (it's a checklist item).
- **Managed signup endpoint** — confirm the desktop has (or add) a `sync_signup` command;
  registration is new-account-only server-side already (§8).
- This plan is **file-layer-adjacent**; the project/inventory/BOM steps belong to the
  maker-app team's lane (§12 step 9). Coordinate the checklist's product-layer items with them.

---

## Sources

[1]: https://productled.com/blog/5-best-practices-for-better-saas-user-onboarding "ProductLed — SaaS onboarding best practices 2025 + checklist"
[2]: https://www.flowjam.com/blog/saas-onboarding-best-practices-2025-guide-checklist "Flowjam — SaaS onboarding best practices 2025 guide + checklist"
[3]: https://www.candu.ai/blog/best-saas-onboarding-examples-checklist-practices-for-2025 "Candu — Best SaaS onboarding examples, checklist & practices 2025"
[4]: https://usertourkit.com/blog/progressive-disclosure-onboarding "userTourKit — Progressive disclosure in onboarding (NN/g-cited)"
[5]: https://support.plex.tv/articles/200288896-basic-setup-wizard/ "Plex — Basic Setup Wizard"
[6]: https://www.candu.ai/blog/how-notion-crafts-a-personalized-onboarding-experience-6-lessons-to-guide-new-users "Candu — How Notion crafts a personalized onboarding experience"
[7]: https://productschool.com/blog/analytics/user-activation "Product School — User activation: the #1 signal your product will scale"
[8]: https://dropbox.tech/mobile/building-dropboxs-new-user-experience-for-mobile-part-1 "Dropbox Tech — Building Dropbox's new user experience"
[9]: https://docs.nextcloud.com/server/stable/admin_manual/installation/installation_wizard.html "Nextcloud — Installation wizard"

- [ProductLed][1] · [Flowjam][2] · [Candu][3] · [userTourKit/NN/g][4] · [Plex][5] ·
  [Candu/Notion][6] · [Product School][7] · [Dropbox Tech][8] · [Nextcloud][9]
