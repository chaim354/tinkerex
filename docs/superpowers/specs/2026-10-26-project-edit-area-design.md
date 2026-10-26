# The project edit area: one Edit button, three tabs

**Date:** 2026-10-26. **Status:** approved in conversation (owner). **Request, verbatim:** "in
projects all the customizations should be condensed to one button and page should all be under
edit".

## 1. Why, and what is there today

The repos went public on 2026-10-26 and the project page is one of the first things a visitor to
the demo opens. Its head carries four ways into changing the project, and the page body two more:

| control | where | what it changes |
|---|---|---|
| **Edit** | head | `/projects/:slug/edit`: name, description, status, tags, type, cover, auto-file |
| **Customise page** | head | `/projects/:slug/layout`: the page in edit mode (arrangement, blocks, tabs, YAML, and a card drafting cover + description) |
| **Publish / Publishing** | head | an anchor to the Publish panel |
| **⋯ menu** | head | Publish settings (the same anchor), Archive / Unarchive, Not a project |
| **Publish panel** | always last on the page | visibility, licence, the consent sentence, copy URL, new unlisted link, Preview, claim a handle |

The owner decided what else counts (2026-10-26, from the full inventory): **Archive and Not a
project move too**; the per-panel Tiles / List / Browser toggles, Edit README, "+ Add panel", Scan
folder, Attach existing and every composer **stay on the page** — they are day-to-day use.

## 2. The project page

A read-only view with one way into editing. The head keeps the cover, the PROJECT eyebrow, the
name, the status badge and the visibility badge (state, not controls), "Public page" (a link out,
for a published project) and "+ Add panel". Its one customising control is **Edit**, which opens
the Details tab.

Gone from the page: Customise page, the Publish / Publishing link, the ⋯ menu, and the Publish
panel itself. The page's accent spend drops from two (Upload + Save publishing) to one (Upload).

## 3. The edit area

One head on all three tabs — "Edit <name>", a tab bar, and **Done** (a link to the project page) —
rendered by one partial so the three cannot drift.

| tab | route | holds |
|---|---|---|
| **Details** | `GET /projects/:slug/edit` (existing) | today's form, unchanged; below it a **Danger zone**: Archive, or Unarchive on an archived project, and Not a project for a discovered one — the ⋯ menu's buttons verbatim (same `button_to`, routes and confirms) |
| **Publishing** | `GET /projects/:slug/publishing` (new member route) | everything the Publish panel held: who can see it, licence, consent sentence, Save publishing, copy URL, unlisted link + New link, claim handle, Preview |
| **Page layout** | `GET /projects/:slug/layout` (existing) | today's in-place editor, unchanged, with the edit head in place of the project head |

**Where each write returns to:**

- Details' **Save changes** → the project page (unchanged). A refusal re-renders Details (unchanged).
- **Save publishing** → **the Publishing tab**, with the same `publish_notice` flash, so a new link is
  on screen to copy. A refusal (no handle, the demo) → the Publishing tab with the alert.
- **Claim handle** → the Publishing tab. **New link** (unlisted token) → the Publishing tab.
- Page layout **Save / Cancel / Reset** → unchanged (the project page; a failed Save → the editor).
- Archive / Not a project → the projects list (unchanged). Unarchive → the projects list (unchanged).

Moving between tabs with an unsaved layout draft drops it, as Cancel does today; no new guard.

**Accents:** Details' Save changes, Publishing's Save publishing and Page layout's Save are each
their page's one primary. The top bar's Upload is quiet on all three (none sets a primary
destination).

## 4. Publish leaves the page-layout vocabulary

The Publish panel existed as a layout key only so the page could hold the settings box; with the
settings in their own tab, keeping `publish` in the vocabulary would leave the editor arranging a
panel nobody sees. So `publish` leaves `Maker::Project::PANELS`, `PANEL_LABELS` and
`Maker::ProjectKind::ALWAYS`, and the pins that kept it last go (`ProjectKind`'s `ordered`,
`Groups`' skip, `LayoutDocument`'s move-to-end note, `_panel_groups`' two `yield "publish"`,
`_panel_slot`'s pinned class, `_panel_strip`'s two Publish branches).

**A stored `panels` column that names `publish` needs nothing**: `layout_for` already intersects the
column with the vocabulary. **A YAML layout exported before this change lists `panel: publish`**, and
an unknown panel is an error that blocks Apply — so `publish` is a **retired** key: Apply skips it
with a note ("Publishing has its own tab now; that entry was skipped."), and a posted draft naming it
is skipped the same way. `projects/_publish` becomes the Publishing tab's body, rendered with locals
as it is today.

## 5. Not changed

The Page layout tab's cover-and-description card stays: the YAML's `page:` mapping drafts through it.
Those two fields are therefore editable on two tabs, which is today's duplication moved closer, not
a new one. The public page, its feed, bundle and BOM CSV never rendered Publish and are untouched.
The README editor, the view toggles and "+ Add panel" are untouched.

## 6. Testing

- The project page renders exactly one control into editing — a link to `edit_project_path` — and
  no link to the layout or publishing routes, no `.project-menu`, no `#publish`; mutation-checked by
  putting Customise page back.
- Each tab renders the shared head with its own tab marked current, and links to the other two.
- Publishing tab: the rendered field names are `project[visibility]` / `project[license]` (§14d);
  saving returns to the tab; refusals return to the tab; handle claim and New link return to it.
- Details: the Danger zone's three buttons, by project state.
- Layout: `publish` absent from `PANELS`; a YAML with `panel: publish` applies with the note; the
  editor renders no Publish slot; a stored column naming `publish` renders.
- `accent_spend_test.rb`: the hub at `["Upload"]`; rows for the three tabs.
- Bare `bin/ci` on all three backend legs.
