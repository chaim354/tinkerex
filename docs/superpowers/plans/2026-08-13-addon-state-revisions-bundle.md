# Addon State Revisions — Boxes Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking a saved box opens the editor prefilled and editing that box; saving appends a revision; a deep link from the library lands in the same place.

**Architecture:** All of it lives in `chaim354/tinkerex-addons`, in `addons/boxes/`. The bundle's client-side router (`boxes.js`) gains a launch path from `host.launch`, the gallery's left click switches destination, and the editor learns an "editing" mode that sends `stateId` and shows a lazily-fetched history.

**Tech Stack:** Plain ESM, no build step, no framework. `@maker/addon-sdk` is a host pin — never vendored, never pinned in `manifests.json`.

**Repo:** `/Users/charlesschwartz/Desktop/tinkerex-addons` (checked out as a sibling)
**Spec:** `docs/superpowers/specs/2026-08-13-addon-state-revisions-design.md` §8, in the tinkerex repo

---

## Prerequisite — do not start until this is true

**The host plan must be merged AND deployed first.** This bundle declares `min_host: 3`, and
publishing it against a host still at level 2 greys the Box Generator out of the gallery. That
ordering is spec §11 and the whole reason `min_host` exists.

Verify against the running deployment, not against the sibling checkout:

```bash
ssh kamal1@192.168.1.95 "docker exec \$(docker ps --format '{{.Names}}' | grep '^tinkerex-web-' | head -1) bin/rails runner 'puts Maker::Addons::Host::LEVEL'"
```

Expected: `3`. If it says 2, stop — the host has not deployed yet.

> **AN EARLIER DRAFT OF THIS STEP CURLED `https://tinkerex.com`, WHICH IS THE WRONG BOX.** That is
> **OVH**, and a bare "deploy" in this project means the three **Unraid** backends only (CLAUDE.md
> §7) — OVH is deployed only on explicit request. So the curl would have reported the host level of
> a machine this arc never touched, and on a green answer it would have been reporting a *stale*
> level rather than the one the bundle is about to bind itself to. Ask the box you actually
> deployed. **Verified live 2026-08-13:** all three Unraid backends run `7005fdb` and answer `3`.

Remember: **publishing the image IS the deploy.** There is no build step and Rails is never
rebuilt, so a mistake here is live the moment `bin/build-push` finishes. `bin/rollback <earlier-sha>`
is the recovery.

---

## File structure

| Path | Change |
|---|---|
| `addons/boxes/boxes.js` | honour `host.launch.stateId` on mount; thread `editingState` through the router |
| `addons/boxes/gallery.js` | left click opens the prefilled editor; right click opens a menu |
| `addons/boxes/editor.js` | editing header, "Save as new box", `stateId` on save, the history panel, the reworded 409 |
| `addons/boxes/history.js` | **new** — the thin revision list, fetched lazily |
| `addons/manifests.json` | `boxes` → `min_host: 3` |

`addons/boxes/show.js` is **kept and not modified** — it is reached from the right-click *Details*
entry instead of a left click, and it is still the only place that lists the bundle's files.

**And in the host repo**, as a separate PR (Task 5):
`tinkerex/test/fixtures/addons/boxes/` — the snapshot the host's system tests drive, which
`bin/check-fixture-drift` refuses to let you publish past.

---

### Task 1: The history panel module

**Files:**
- Create: `addons/boxes/history.js`

- [ ] **Step 1: Write the module**

```javascript
// See boxes.js's import for why this is a static import of the host pin and never a vendored copy.
// `host` is a LIVE BINDING — read through it at call time, never captured at module top level.
import { host } from "@maker/addon-sdk"

// A saved box's revision history: revision number, date, and a click that loads those params back
// into the form. Deliberately thin — no delete, no diff, no annotation (design §2).
//
// FETCHED LAZILY, ON FIRST EXPAND. The states list carries only the current `revision` number, so
// a gallery of forty boxes pays nothing for histories nobody opened; this is the call that pays
// for one.
//
// container: where to render. stateId: the box. currentRevision: what the editor is showing now.
// onLoad(params): put those values in the form. Returns a destroy callback.
export function mountHistory(container, { stateId, currentRevision, onLoad }) {
  container.innerHTML = `
    <details class="box-history">
      <summary class="box-history-summary">
        History <span class="box-toc-count" data-role="count"></span>
      </summary>
      <div data-role="body"><p class="muted">Loading…</p></div>
    </details>`

  const details = container.querySelector("details")
  const body = container.querySelector('[data-role="body"]')
  container.querySelector('[data-role="count"]').textContent = String(currentRevision ?? "")

  let loaded = false
  const onToggle = async () => {
    if (!details.open || loaded) return
    loaded = true
    try {
      render(await host.state.revisions(stateId))
    } catch (e) {
      // A failed history must not look like an empty one — an empty list is a claim about the
      // box, and this is a claim about the request.
      loaded = false
      body.innerHTML = `<p class="muted">Couldn't load the history: ${escapeHtml(e.message)}</p>`
    }
  }

  const render = (revisions) => {
    body.innerHTML = ""
    if (!revisions.length) {
      body.innerHTML = `<p class="muted">No revisions recorded.</p>`
      return
    }
    const ul = document.createElement("ul")
    ul.className = "box-history-list"
    for (const rev of revisions) {
      const li = document.createElement("li")
      const button = document.createElement("button")
      button.type = "button"
      button.className = "linkbtn"
      button.textContent = `v${rev.revision}`
      button.addEventListener("click", () => onLoad(rev.data?.params || {}))
      const date = document.createElement("span")
      date.className = "muted"
      date.textContent = String(rev.created_at).slice(0, 10)
      if (rev.revision === currentRevision) li.classList.add("is-current")
      li.append(button, date)
      ul.appendChild(li)
    }
    body.appendChild(ul)
  }

  details.addEventListener("toggle", onToggle)
  return { destroy: () => details.removeEventListener("toggle", onToggle) }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/charlesschwartz/Desktop/tinkerex-addons
git add addons/boxes/history.js
git commit -m "feat(boxes): a thin revision history panel"
```

---

### Task 2: The editor edits a box

**Files:**
- Modify: `addons/boxes/editor.js`

- [ ] **Step 1: Accept an `editingState` and render the header**

`mountEditor` currently takes `{ generator, states, ctx, prefillValues, onBack, onSaved,
onOpenGenerator }`. Add `editingState` (the full state object, or null) and `onOpenState`.

In the `page-head` block, after the `<p class="page-subtitle">`:

```html
        <p class="box-editing" data-role="editing" hidden></p>
```

After the existing `$("title").textContent = …` assignments:

```javascript
  // WHICH BOX THIS EDITOR IS EDITING, if any. Present -> Save appends a revision to it; absent ->
  // Save creates a new box. The user must be able to see which, because the two are different acts
  // and the button says the same word for both.
  if (editingState) {
    $("editing").hidden = false
    $("editing").textContent = `Editing “${editingState.name}” · v${editingState.revision ?? 1}`
    $("name").value = editingState.name
  }
```

- [ ] **Step 2: Add the "Save as new box" button**

In the `page-actions` div, between Preview and Save:

```html
            <button type="button" data-role="save-as-new" class="btn ghost" hidden>Save as new box</button>
```

And after the editing header block:

```javascript
  // ONLY MEANINGFUL WHILE EDITING — a fresh generator's Save already creates a new box, so a
  // second button saying so would be two controls for one act.
  $("save-as-new").hidden = !editingState
```

- [ ] **Step 3: Send `stateId` on save**

In `onSaveClick`, the `host.files.save({…})` call gains one option. Add a parameter so the same
handler serves both buttons:

```javascript
  // `asNew` is what the "Save as new box" button passes: it forks the design rather than appending
  // to the box currently open. Everything else about the save is identical, which is why this is a
  // parameter and not a second handler.
  const onSaveClick = async (asNew = false) => {
```

and inside the save call, after `data:`:

```javascript
        // OMITTED ENTIRELY when this is a new box — the SDK only puts `state_id` on the wire when
        // it is passed, so a fresh save sends byte-identical requests to what it always has.
        stateId: asNew || !editingState ? null : editingState.id,
```

Wire both buttons:

```javascript
  const onSave = () => onSaveClick(false)
  const onSaveNew = () => onSaveClick(true)
  $("save").addEventListener("click", onSave)
  $("save-as-new").addEventListener("click", onSaveNew)
```

and remove both in the destroy callback.

- [ ] **Step 4: Reword the 409 so it offers the revision**

Replace the `onReplace` callback's body:

```javascript
        // THE 409 IS A QUESTION, AND ANSWERING YES MEANS "make this a revision of that box". A
        // same-name save started from a blank generator is the ordinary way somebody re-opens a
        // design they saved last week — joining the existing lineage is what stops it minting a
        // second box over the same file.
        //
        // The retry carries `stateId`, which is why `owner` is looked up here rather than the
        // dialog simply saying yes: without it the host would replace the file and still create an
        // unrelated box, which is the exact pile-up this feature exists to end.
        onReplace: (replaceFiles) => {
          const owner = editingState || findStateOwning(states, replaceFiles)
          const question = owner
            ? `Save as revision ${(owner.revision ?? 1) + 1} of “${owner.name}”?`
            : "Replace with this version?"
          return window.confirm(
            `This will replace ${replaceFiles.length === 1 ? "a file" : "files"} you already saved:\n\n` +
              `${replaceFiles.map((f) => `  ${f.name}  (in ${f.folder}/)`).join("\n")}\n\n${question}`,
          )
        },
```

Add the lookup at module scope:

```javascript
// WHICH SAVED BOX OWNS THE FILES A 409 NAMED, by filename. A guess, and deliberately a conservative
// one: it matches only when exactly one saved box's name slugs to the colliding file's base, so an
// ambiguous answer falls back to the plain "Replace?" question rather than silently appending a
// revision to the wrong design.
function findStateOwning(states, replaceFiles) {
  const bases = new Set(replaceFiles.map((f) => String(f.name).replace(/(-plan)?\.svg$/, "")))
  const matches = states.filter((s) => bases.has(slugify(s.name)))
  return matches.length === 1 ? matches[0] : null
}

function slugify(name) {
  return String(name).replace(/[^a-z0-9]+/gi, "-").toLowerCase() || "box"
}
```

**Note the duplication this creates:** `slugify` repeats the `base` derivation inside `onSaveClick`.
Extract that one expression into `slugify` and call it from both — one definition, since a drift
between them would make the dialog name the wrong box.

- [ ] **Step 5: Mount the history panel**

Add a container to the aside, after the top-view panel:

```html
        <div data-role="history"></div>
```

and after `renderPrior(...)`:

```javascript
  // ONLY WHEN EDITING: a fresh generator has no box and therefore no history, and an empty panel
  // there would read as "this generator has never been used".
  if (editingState) {
    const history = mountHistory($("history"), {
      stateId: editingState.id,
      currentRevision: editingState.revision ?? 1,
      onLoad: (params) => onOpenGenerator(generator.key, params, editingState),
    })
    destroyers.push(history)
  }
```

Import it at the top: `import { mountHistory } from "./history.js"`.

- [ ] **Step 6: Verify by hand in a browser**

There is no headless harness in this repo. With the host running locally against
`ADDON_SOURCE_PATH` pointed at this checkout, open `/tools/boxes`, click a saved box, and confirm:
the header names it, the Name field is filled, the params are filled, History expands and lists
revisions, clicking `v1` refills the form, Save says "Saved." and the states list does not grow.

- [ ] **Step 7: Commit**

```bash
git add addons/boxes/editor.js
git commit -m "feat(boxes): the editor edits a saved box, and saving appends a revision"
```

---

### Task 3: The gallery's left click, and a right-click menu

**Files:**
- Modify: `addons/boxes/gallery.js`

- [ ] **Step 1: Change what a left click does**

`mountGallery`'s `onOpenState(state)` currently opens the detail view. Rename the callbacks it
takes to say which is which: `onEditState(state)` and `onShowState(state)`.

In `renderSavedRail`, replace the link's click handler:

```javascript
        a.addEventListener("click", (e) => { e.preventDefault(); onEditState(state) })
        // RIGHT CLICK IS THE SECONDARY MENU, mirroring the host's own file cells. The left click is
        // the common act (open the form with these values); everything rarer lives here.
        a.addEventListener("contextmenu", (e) => {
          e.preventDefault()
          openSavedMenu(e, state, { onEditState, onShowState })
        })
```

- [ ] **Step 2: Add the menu**

At module scope:

```javascript
// A small right-click menu on a saved box. Deliberately built the same way the host's own filemenu
// builds one — a positioned div of plain buttons, closed on the next document click or Escape —
// rather than a component, because this bundle has no framework and the host's controller does not
// reach markup a bundle injects.
function openSavedMenu(event, state, { onEditState, onShowState }) {
  closeSavedMenu()
  const menu = document.createElement("div")
  menu.className = "file-menu"
  menu.style.left = `${event.pageX}px`
  menu.style.top = `${event.pageY}px`

  const entry = (label, fn) => {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = label
    b.addEventListener("click", (e) => { e.stopPropagation(); closeSavedMenu(); fn() })
    menu.appendChild(b)
  }

  entry("Open prefilled", () => onEditState(state))
  entry("Details", () => onShowState(state))

  // The FIRST output file, which for every box this bundle saves is the drawing itself. `/files/…`
  // is the host's own long-standing route; see show.js's header for why this bundle tolerates
  // hardcoding it and what breaks quietly if it ever moves.
  const first = state.files?.[0]
  if (first) {
    const open = document.createElement("a")
    open.href = `/files/${encodeURIComponent(first.node_id)}`
    open.textContent = "Open the file"
    menu.appendChild(open)
  }

  document.body.appendChild(menu)
  savedMenu = menu
  // Registered on the NEXT tick: registering now would let this same click close the menu it just
  // opened.
  setTimeout(() => {
    document.addEventListener("click", closeSavedMenu, { once: true })
    document.addEventListener("keydown", onSavedMenuKey)
  }, 0)
}

let savedMenu = null
function onSavedMenuKey(e) { if (e.key === "Escape") closeSavedMenu() }
function closeSavedMenu() {
  savedMenu?.remove()
  savedMenu = null
  document.removeEventListener("keydown", onSavedMenuKey)
}
```

Call `closeSavedMenu()` from `mountGallery`'s returned destroy callback, so a Turbo navigation
cannot leave an orphaned menu on the page.

- [ ] **Step 3: Commit**

```bash
git add addons/boxes/gallery.js
git commit -m "feat(boxes): a saved box opens the form; the menu holds the rest"
```

---

### Task 4: The router and the deep link

**Files:**
- Modify: `addons/boxes/boxes.js`
- Modify: `addons/manifests.json`

- [ ] **Step 1: Thread the editing state through the router**

Replace the three router functions in `mount`:

```javascript
    const showGallery = () =>
      swap(() => mountGallery(page, {
        generators, states, onOpenGenerator: showEditor,
        onEditState: (state) => showEditor(state.data?.generator, state.data?.params || {}, state),
        onShowState: showState,
      }))

    // `editingState` present -> Save appends a revision to that box; absent -> Save creates one.
    const showEditor = (key, prefillValues, editingState = null) => {
      const generator = generators.find((g) => g.key === key)
      if (!generator) { showGallery(); return } // an unknown/removed generator key -> back to the gallery
      swap(() => mountEditor(page, {
        generator, states, ctx, prefillValues, editingState,
        onBack: showGallery,
        onOpenGenerator: showEditor,
        onSaved: async () => { try { states = await fetchStates() } catch (_e) { /* keep the stale list */ } },
      }))
    }

    const showState = (state) =>
      swap(() => mountShow(page, {
        state, ctx, onBack: showGallery,
        onDuplicate: (key, params) => showEditor(key, params),
      }))
```

Note `onDuplicate` passes **no** `editingState` — "Duplicate & tweak" forks a design, which is the
one place in this bundle where opening a saved box's params deliberately does *not* mean editing it.

- [ ] **Step 2: Honour the deep link**

Replace the final `showGallery()` at the end of `mount`:

```javascript
    // A DEEP LINK FROM THE LIBRARY. `host.launch.stateId` is the host's own validated answer to
    // `?state=` — it has already refused an id belonging to another user or another addon, so an
    // id that arrives here is real and this only has to find it in the list it already fetched.
    //
    // A state whose generator the sidecar no longer offers falls through to the gallery, the same
    // degrade showEditor already performs for an unknown key.
    const launchId = host.launch?.stateId
    const launched = launchId ? states.find((s) => s.id === launchId) : null
    if (launched) {
      showEditor(launched.data?.generator, launched.data?.params || {}, launched)
    } else {
      showGallery()
    }
```

- [ ] **Step 3: Declare the host requirement**

In `addons/manifests.json`, change the `boxes` entry's `min_host` from `1` to `3`.

**This is the line that makes the ordering matter.** On a host below level 3 the addon greys out
with a reason rather than silently saving new boxes where the user asked for revisions.

- [ ] **Step 4: Verify by hand**

Against a local host at level 3: open `/tools/boxes?state=<a real id>` and confirm it lands
directly in the prefilled editor, editing that box. Then open `/tools/boxes?state=999999` and
confirm it lands on the gallery with no error.

- [ ] **Step 5: Commit**

```bash
git add addons/boxes/boxes.js addons/manifests.json
git commit -m "feat(boxes): open a saved box straight from a library deep link"
```

---

### Task 5: Mirror the snapshot into the host repo

**This is not bookkeeping — it is a gate, and it lands in the OTHER repo.**

`tinkerex/test/fixtures/addons/boxes/` is a **snapshot** of this bundle, because the host's CI has
no checkout of this repo beside it and a test depending on a sibling gives zero coverage on a fresh
clone. Six host system tests drive that snapshot (`box_sections_test.rb`, `box_save_folder_test.rb`,
`tray_layout_test.rb`, `tray_top_view_test.rb`, `plan_export_test.rb`, and `addon_bundle_test.rb`
via its own separate fixture). `bin/check-fixture-drift` **fails the publish** when the two trees
disagree — deliberately, at the last moment both are on disk and the person who edited one is still
there.

- [ ] **Step 1: Copy the changed modules across**

```bash
cp /Users/charlesschwartz/Desktop/tinkerex-addons/addons/boxes/{boxes.js,gallery.js,editor.js,history.js} /Users/charlesschwartz/Desktop/tinkerex/test/fixtures/addons/boxes/
```

- [ ] **Step 2: Confirm the trees agree**

```bash
cd /Users/charlesschwartz/Desktop/tinkerex-addons && bin/check-fixture-drift
```

Expected: no `FAIL:` lines. A `WARNING: no host fixtures` line means `TINKEREX_PATH` is unset and the
check did **not** run — fix that rather than accepting it.

- [ ] **Step 3: Run the host's boxes system tests against the new snapshot**

These drive the editor's markup, which Task 2 changed. This is where an added element that broke a
selector shows up.

```bash
cd /Users/charlesschwartz/Desktop/tinkerex && bin/rails test:system TEST=test/system/box_sections_test.rb
```

```bash
cd /Users/charlesschwartz/Desktop/tinkerex && bin/rails test:system TEST=test/system/box_save_folder_test.rb
```

Then `tray_layout_test.rb`, `tray_top_view_test.rb` and `plan_export_test.rb` the same way. Fix any
break in the **bundle**, then re-copy — never by editing the snapshot alone, which is exactly the
drift this gate exists to catch.

- [ ] **Step 4: Commit the snapshot in the host repo, on its own branch**

```bash
cd /Users/charlesschwartz/Desktop/tinkerex && git checkout -b claude/boxes-revision-fixture && git add test/fixtures/addons/boxes && git commit -m "test(fixtures): mirror the boxes bundle's revision support"
```

That is a **second host PR**, opened and merged alongside the bundle PR.

---

### Task 6: Publish

- [ ] **Step 1: Re-verify the deployed host level**

```bash
curl -s https://tinkerex.com/tools/boxes | grep -o '"hostLevel":[0-9]*'
```

Expected: `"hostLevel":3`. **Do not publish otherwise.**

- [ ] **Step 2: Open the PR, and publish only after it merges**

Publishing is the deploy, so it follows the merge rather than preceding it:

```bash
bin/build-push
```

- [ ] **Step 3: Verify live, and know the rollback**

Open `/tools/boxes` on the deployment. If anything is wrong:

```bash
bin/rollback <previous-sha>
```

---

## Done when

- A saved box opens the form with its values, from the gallery and from a library deep link.
- Saving appends a revision instead of minting a second box; the saved rail stops growing.
- The right-click menu offers Details and the file.
- `bin/check-fixture-drift` passes with the sibling present, and the host's five boxes system tests
  are green against the mirrored snapshot.
- The bundle is published and verified live, with the rollback sha to hand.
