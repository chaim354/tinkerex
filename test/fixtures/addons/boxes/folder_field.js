// The "save to folder" control, in whichever shape the HOST can support.
//
// TWO SHAPES, FEATURE-DETECTED, AND BOTH HAVE TO STAY. `ctx.chooseFolder` is the host's
// Miller-columns chooser, handed across as a plain function; `ctx.folders` is the older flat
// [label, node_id] list this bundle used to build a <select> from. This repo and the Rails app
// deploy INDEPENDENTLY — publishing this image IS the addon deploy and Rails is never rebuilt, and
// `bin/rollback` can put an older image back at any moment — so a bundle is routinely running
// against a host of the other vintage. Assuming the new key is how a rollback becomes a save UI
// with no way to pick a folder at all; the host, symmetrically, still sends `folders` for exactly
// the same reason. Neither side drops its half until the other has nothing reachable that reads it.
//
// THE CLASS NAMES BELOW ARE THE HOST'S (`folder-field`, `folder-field-btn`, `ff-path`, from its
// application.css), and that is not a layering mistake: a bundle runs same-origin inside the host's
// own page and has no stylesheet of its own — every other class in this bundle is the host's too.
// A host new enough to provide `chooseFolder` is by construction new enough to have the CSS, since
// they ship in the same commit; an older one never reaches this branch.
//
// -> { value() } — the chosen node_id, "" meaning the library root. A getter rather than a stored
// value because the two shapes hold it in different places (a <select>'s value vs. a closure), and
// the caller should not have to know which one it got.
export function mountFolderField(slot, ctx) {
  return typeof ctx.chooseFolder === "function" ? mountChooser(slot, ctx) : mountSelect(slot, ctx)
}

function mountChooser(slot, ctx) {
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
    const selection = await ctx.chooseFolder({ value: nodeId, label: path.textContent })
    // A CANCEL IS NOT "THE LIBRARY ROOT". The host resolves null for Esc/Cancel/backdrop and
    // {nodeId: ""} for a deliberate choice of the root; collapsing them here would silently move
    // the user's destination to the root every time they backed out of the modal.
    if (!selection) return
    nodeId = selection.nodeId
    path.textContent = selection.path
  })
  return { value: () => nodeId }
}

// The pre-chooser control, unchanged in behaviour from when it was inline in the editor: a flat
// <select> of every folder the user owns, root first, with the current project's folder preselected.
function mountSelect(slot, ctx) {
  const select = document.createElement("select")
  select.dataset.role = "folder"
  for (const [ label, id ] of ctx.folders || []) {
    const opt = new Option(label, id)
    if (id === ctx.defaultFolder) opt.selected = true
    select.add(opt)
  }
  slot.appendChild(select)
  return { value: () => select.value }
}
