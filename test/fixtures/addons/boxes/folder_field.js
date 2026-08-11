// The "save to folder" control: the host's own Miller-columns folder chooser, reached through the SDK.
//
// THE `ctx.folders` <select> FALLBACK IS GONE, AND REMOVING IT IS NOT A SIMPLIFICATION — it was a
// feature detect for something that can no longer happen. It existed because this repo and the
// Rails app deploy INDEPENDENTLY (publishing this image IS the addon deploy; Rails is never
// rebuilt), so a bundle is routinely running against a host of the other vintage, and a host that
// predated `ctx.chooseFolder` had to get a flat <select> rather than a save UI with no way to pick
// a folder at all. That argument does not survive this bundle's SDK import: a host old enough to
// lack `chooseFolder` is a host that does not pin "@maker/addon-sdk" either, so the ENTRY MODULE
// (boxes.js) never resolves, mount() is never called, and this file is never reached. The <select>
// branch was reachable only from a host that can no longer run any part of this bundle — a branch
// nothing can take and nothing can test, which is the shape tinkerex CLAUDE.md §15 warns about (a
// guard that has never failed has not been shown to work). The recovery for a genuinely old host is
// `bin/rollback <sha>` in this repo, putting the pre-SDK bundle image back; it is not a dead branch
// carried inside the new one.
//
// WHAT REPLACES THE ctx SHAPE PROBE IS THE CAPABILITY MAP, ASKED BY THE SDK AT CALL TIME.
// `pick:folder` is true on this host; if a future host answers false, `pickFolder` throws
// UnsupportedCapabilityError BEFORE any request. That refusal is REPORTED rather than swallowed —
// an uncaught rejection inside a click handler leaves the button doing nothing at all, which looks
// exactly like a cancel and teaches the user the control is broken with no way to know why.
//
// STILL READS `ctx` FOR TWO VALUES, DELIBERATELY. `ctx.defaultFolder` (a STRING node id) and
// `ctx.defaultFolderLabel` have no SDK accessor and must not grow one: the server's own ctx blob
// spells the same idea `defaultFolder: {nodeId, label}`, so a `host.defaultFolder` would hand an
// OBJECT to every bundle that expects a string. docs/addon-api-v1.md §6.2 — the raw ctx values keep
// being passed to mount() and keep working; the SDK is an addition, not a replacement.
//
// THE CLASS NAMES BELOW ARE THE HOST'S (`folder-field`, `folder-field-btn`, `ff-path`, from its
// application.css), and that is not a layering mistake: a bundle runs same-origin inside the host's
// own page and has no stylesheet of its own — every other class in this bundle is the host's too.
//
// -> { value() } — the chosen node_id, "" meaning the library root. A getter rather than a stored
// value so the caller never has to know where the current choice is held.
import { host } from "@maker/addon-sdk"

export function mountFolderField(slot, ctx, report = (msg) => console.error(msg)) {
  let nodeId = ctx.defaultFolder || ""
  slot.innerHTML = `<span class="folder-field">
      <button type="button" class="folder-field-btn" data-role="folder-btn">
        <span aria-hidden="true">📁</span>
        <span class="ff-path"></span>
        <span aria-hidden="true">▾</span>
      </button>
    </span>`
  const path = slot.querySelector(".ff-path")
  // textContent, not innerHTML: this is a path built from the user's own folder names.
  path.textContent = ctx.defaultFolderLabel || "/ (library root)"

  slot.querySelector("[data-role=folder-btn]").addEventListener("click", async () => {
    let selection
    try {
      // READ THROUGH `host` AT CALL TIME, never a top-level capture. This listener outlives the
      // module's own evaluation — an ES module is evaluated once per URL per page while the host is
      // rebuilt on every mount — which is precisely the case a captured reference gets wrong with
      // nothing thrown and nothing logged.
      selection = await host.files.pickFolder({ value: nodeId, label: path.textContent })
    } catch (e) {
      report(`Couldn't open the folder chooser: ${e.message}`)
      return
    }
    // A CANCEL IS NOT "THE LIBRARY ROOT". The host resolves null for Esc/Cancel/backdrop and
    // {nodeId: ""} for a deliberate choice of the root; collapsing them here would silently move
    // the user's destination to the root every time they backed out of the modal.
    if (!selection) return
    nodeId = selection.nodeId
    path.textContent = selection.path
  })
  return { value: () => nodeId }
}
