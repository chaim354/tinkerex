# Box Generator — layout fix + per-generator history

**Date:** 2026-07-20
**Status:** approved (design)
**Scope:** the Box Generator addon UI only (`Tools::BoxesController` + its views + CSS + one
Stimulus controller). No sync/file-layer changes (§10 tripwire), no sidecar changes, no change to
the save flow.

## Problem

Three gaps in the shipped Box Generator (`/tools/boxes`):

1. **The editor is unstyled.** Every box-specific CSS class (`box-editor`, `box-params`,
   `box-field`, `box-preview`) has *zero* rules in `application.css`. The `new` view intends a
   two-column form-plus-preview layout but renders as one cramped column; the param fields stack
   in a single narrow column regardless of how many the generator has.
2. **The picker is a wall.** `index` dumps all ~185 generators into one flat `.tools-grid`, with
   no grouping and no search.
3. **No per-generator history.** Clicking a generator jumps straight to a blank editor. The only
   way to reuse a prior box's parameters is the "Duplicate & tweak" link buried on that one saved
   box's `show` page. You can't see "what have I made with *this* generator" or reload its
   settings from the place you'd build a new one.

## Approach

Three changes, all in the addon's own UI layer.

### 1. Editor two-column layout (CSS + `new` view)

- Add real CSS for the existing classes: `.box-editor` becomes a responsive two-column grid
  (params form on the left; a right column holding the live preview and the history rail),
  collapsing to one column on narrow viewports. `.box-params` becomes a field grid
  (`auto-fill, minmax(...)`) instead of a single stacked column. `.box-field` / `.box-field-label`
  get spacing and label styling. The preview column is sticky so it stays in view while scrolling
  a long param list.
- Markup in `new.html.erb` / `_form.html.erb` changes only as needed to support the grid
  (wrappers/class names); the dynamic-field logic and the `boxpreview` controller are untouched.

### 2. Grouped, searchable picker (`index` view + one Stimulus controller)

- Group `@generators` by their existing `group` field (`client.generators` already returns
  `group` per generator) into `<section>`s with headers. Reuse `.addon-card` for the cards.
- A new `boxfilter` Stimulus controller does **live client-side filtering**: typing in a search
  box hides non-matching cards (match on title + key + group) and hides group headers that end up
  empty. No server round-trip. With no JS it degrades to the full grouped list.
- Restyle the existing "Saved boxes" global list at the bottom into compact cards (kept as a
  recent-across-all-generators list).

### 3. "Made with this generator" rail + import (the `new` action)

- `new` loads `@prior` = this user's saved boxes for this generator, newest first:
  `current_user.maker_addon_states.for_addon("boxes")` ordered by `updated_at`, then **filtered in
  Ruby** by `state.data["generator"] == @generator.key`.
  - *Why Ruby, not SQL:* `data` is a JSON column and a `data->>'generator'` query is
    Postgres-specific — it differs on SQLite, violating the repo's adapter-agnostic rule (§CLAUDE
    "no PG-only SQL"). The set is a single user's saved boxes (tens, maybe low hundreds); loading
    and filtering in Ruby is fine. If it ever matters, denormalize an indexed column later —
    YAGNI now, and it keeps the generic `AddonState` model free of a boxes-specific column.
- The right-column rail renders one row per prior box: a **thumbnail**, the box name, its date,
  and a **Load** link. The rail is hidden (with a quiet muted hint) when `@prior` is empty — which
  is the common case across 185 generators.
- **Thumbnails reuse the existing machinery, no new query.** Each row's thumbnail is the PNG
  preview of that box's `output` node (the `AddonFile` with `role: "output"`). The rail wraps its
  rows in the existing `thumbs` Stimulus controller pointed at the existing `GET /files/thumbnails`
  endpoint (already batched, already handles ready / pending / unsupported-badge), with each row a
  cell carrying its output `node_id`. Box-icon fallback while a preview is pending. (Saved-box
  previews are enqueued at save time, so on a revisit they are almost always already ready.)
- **Load reuses the existing prefill path — no new endpoint, no new JS.** The Load link points at
  `new_tools_box_path(generator: @generator.key, params: state.data["params"])`, exactly what
  "Duplicate & tweak" already uses. It reloads the editor with the param fields filled from the
  saved box; the **name field is left blank** (you're creating a new box, matching current
  duplicate behavior). The `new` action already reads `params[:params]` as the optional prefill.

## Data flow

- **History link:** `AddonState#data["generator"]` is the join key back to the generator. No schema
  change.
- **Import:** saved `data["params"]` → query string → `new`'s existing `@values` prefill → the
  `_form` partial's `values` local. Round-trips through mechanisms that already exist.
- **Rail thumbnails:** output `node_id` → `/files/thumbnails` (unchanged) → `thumbs` controller
  (unchanged) swaps the image in.

## Error / edge handling

- Unknown `generator` param on `new`: already redirects to the index with an alert — unchanged.
- Empty history: rail hidden with a muted "No saved boxes with this generator yet." hint.
- A prior box whose `output` preview isn't ready (or is unsupported): icon fallback, via the
  existing `_thumb` states — no special-casing.
- A prior box missing an `output` file (shouldn't happen given the save flow always writes one):
  render the row with the icon fallback rather than raising.

## Testing

- **Controller (`new`):** create two `AddonState`s for two different generators for the user;
  assert `@prior` contains only the matching generator's, newest first. Reuses the `FakeBoxes`
  stub (`test/support/fake_boxes.rb`).
- **Controller (`index`):** assert the response groups generators under their group headers and
  renders the saved-boxes section.
- **Import:** assert the Load link for a prior box carries `generator` and its saved `params` in
  the URL (i.e. resolves to the existing prefill path).
- Runs on all three backend legs (`bin/rails test`, `LIBRARY_BACKEND=share`, `=s3`) like the rest
  of the addon's tests. CSS/layout itself isn't unit-tested (no system-test harness for it here).

## Out of scope / non-goals

- No changes to the save/generate flow, `LibraryOutput`, `BoxesClient`, or the sidecar.
- The two known addon v1 deferrals stay deferred: no auto-created per-save folders, no in-place
  regenerate/versioning (each save still creates a fresh bundle).
- No sync engine, changelog, conflict, lock, or mount changes (§10 tripwire).
