import { Controller } from "@hotwired/stimulus"

// Right-click a row → a small menu (Add note / Open / Details / Download / Edit in <Addon> / Delete).
// "Add note" opens a popover with a textarea that POSTs to the file's notes endpoint (JSON), then
// reloads so the server-rendered badge is correct. "Details" opens the Library's side panel for the
// file — in place on the Library, by navigating there anywhere else (see the entry below).
// Progressive enhancement: with no JS, right-click is the browser's own menu, notes stay fully
// usable from the file detail page, and the list's own row-actions cell still carries a Delete
// button.
//
// EVERY ENTRY IS BUILT FROM A `data-` ATTRIBUTE ON THE CELL, never from a URL assembled here. The
// cell carries `data-note-url`, `data-download-url`, `data-delete-url`, `data-details-url` and
// `data-addon-open-url`, all written by the server's own route helpers
// (files_helper.rb#file_menu_data and #folder_menu_data) — so this controller cannot get a path
// shape wrong, and a surface that does not want an entry simply omits the attribute rather than
// needing a flag.
//
// WHICH MEANS EVERY ENTRY IS INDEPENDENTLY OPTIONAL, and since 2026-09-10 that is load-bearing
// rather than incidental: a FOLDER's cell carries the delete url alone.
//
// IT IS A MENU TO A KEYBOARD AND A SCREEN READER TOO (2026-11-02, the UX audit's D2 and §I). It was a
// bare `div` of buttons and links appended to <body>: nothing announced it, focus stayed on the row
// behind it, and a keyboard user who opened it with Shift+F10 had to Tab through the whole page to
// reach it. Now it is the WAI-ARIA menu pattern: `role="menu"` holding `role="menuitem"` entries
// that sit out of the Tab order (tabIndex -1) and take focus one at a time — the first on open,
// Up/Down (wrapping) and Home/End to move, Enter/Space to activate, Escape to close with focus back
// on the row that opened it, and Tab to close and carry on from that row. Shift+F10 and the
// ContextMenu key open it from a focused row, anchored under the row rather than at a pointer that
// was never there.
export default class extends Controller {
  connect() {
    this.onDocClick = () => this.close()
    this.onKey = (e) => {
      if (e.key !== "Escape" || !(this.menu || this.popover)) return
      this.close()
      this.returnFocus()
    }
    // DELEGATED, because the menu-bearing cells are server-rendered links whose `data-action`
    // already names the contextmenu door (FilesHelper#file_menu_data); a second per-cell action for
    // the keyboard would have to be added to every surface that writes that payload.
    this.onCellKey = (e) => {
      if (!(e.key === "ContextMenu" || (e.key === "F10" && e.shiftKey))) return
      const cell = e.target.closest?.(MENU_CELL)
      if (!cell || !this.element.contains(cell) || !hasMenu(cell)) return
      e.preventDefault()
      this.show(cell, belowOf(cell))
    }
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKey)
    this.element.addEventListener("keydown", this.onCellKey)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
    this.element.removeEventListener("keydown", this.onCellKey)
    this.close()
  }

  // data-action="contextmenu->filemenu#open" on each menu-bearing cell.
  open(event) {
    const cell = event.currentTarget
    // THE GATE ASKS WHETHER THERE IS A MENU TO SHOW, NOT WHETHER THERE ARE NOTES. It read
    // `if (!noteUrl) return` until 2026-09-10, which was correct while every menu-bearing cell was a
    // FILE and every file had notes. A folder has a delete url and nothing else, so the old gate
    // would have opened no menu for it AT ALL — silently, because a contextmenu handler that returns
    // early is indistinguishable from one that never ran, and the browser's own menu appears in its
    // place. Any new entry must widen `hasMenu` too, or it ships behind a gate that hides it.
    if (!hasMenu(cell)) return
    event.preventDefault()
    // A POINTER INSIDE THE CELL is where a right-click put it; anything else (a keyboard-raised
    // contextmenu reports the page origin, or a point the row no longer covers) anchors under the row.
    this.show(cell, pointerInside(cell, event) ? { x: event.pageX, y: event.pageY } : belowOf(cell))
  }

  show(cell, at) {
    this.close()
    // WHERE FOCUS GOES BACK TO: the focused element when that is inside the cell (a project row is a
    // `tr` around its link), else the cell itself when it can take focus, else its first link.
    const active = document.activeElement
    this.returnTo = (active && active !== document.body && cell.contains(active)) ? active
      : (cell.matches(FOCUSABLE) ? cell : cell.querySelector(FOCUSABLE))

    const noteUrl = cell.dataset.noteUrl
    const deleteUrl = cell.dataset.deleteUrl
    const href = cell.getAttribute("href") || cell.querySelector("a")?.getAttribute("href")
    this.menu = document.createElement("div")
    this.menu.className = "file-menu"
    this.menu.setAttribute("role", "menu")
    this.menu.setAttribute("aria-label", cell.dataset.nodeName ? `Actions for ${cell.dataset.nodeName}` : "Actions")
    this.menu.style.left = `${at.x}px`
    this.menu.style.top = `${at.y}px`
    this.menu.addEventListener("keydown", (e) => this.navigate(e))
    // NO BROWSER MENU OVER THIS ONE. Where the ContextMenu key raises `contextmenu` on key-UP
    // (Windows), it lands on the menu item that took focus on key-down, outside every cell — so the
    // cell's own handler never sees it and the native menu would open on top of this one. A
    // right-click on an entry is answered the same way.
    this.menu.addEventListener("contextmenu", (e) => e.preventDefault())

    // GUARDED NOW THAT THE GATE NO LONGER IMPLIES IT. Before, reaching this line proved `noteUrl`
    // was present; a folder reaches it with none, and `openPopover(undefined)` would POST to
    // "undefined" from a menu entry that looked perfectly ordinary.
    if (noteUrl) {
      const add = document.createElement("button")
      add.type = "button"
      add.textContent = "Add note"
      add.addEventListener("click", (e) => { e.stopPropagation(); this.closeMenu(); this.openPopover(noteUrl, at.x, at.y) })
      this.add(add)
    }

    if (href) {
      const open = document.createElement("a")
      open.href = href
      open.textContent = "Open"
      this.add(open)
    }

    // DETAILS — the Library's side panel for this file (2026-10-21). The CELL is asked first, through
    // a cancelable `filemenu:details` event: on the Library the tile is a selection item and
    // selection_controller.js#details opens the panel in place and cancels it. Anywhere else nothing
    // cancels it and the entry is an ordinary link to `data-details-url` — the Library with this file
    // selected, a URL the server built (file_menu_data) like every other entry here. The document's
    // own click listener closes the menu afterwards, as it does for Open.
    const detailsUrl = cell.dataset.detailsUrl
    if (detailsUrl) {
      const details = document.createElement("a")
      details.href = detailsUrl
      details.textContent = "Details"
      details.addEventListener("click", (e) => {
        const asked = this.dispatch("details", { target: cell, cancelable: true })
        if (asked.defaultPrevented) e.preventDefault()
      })
      this.add(details)
    }

    // The URL already carries ?download=1, so FilesController#blob answers
    // `Content-Disposition: attachment` whatever the content type would otherwise allow inline.
    // NO `download` ATTRIBUTE HERE, deliberately: on chunk and s3 the blob endpoint 302s to a
    // presigned, CROSS-ORIGIN storage URL, and the HTML `download` attribute is IGNORED on a
    // cross-origin navigation — so it would work on share and silently open-in-tab on the app's
    // main deployment. The server-set header is the one mechanism that holds on all three.
    const downloadUrl = cell.dataset.downloadUrl
    if (downloadUrl) {
      const dl = document.createElement("a")
      dl.href = downloadUrl
      dl.textContent = "Download"
      this.add(dl)
    }

    // "Edit in <Addon>" — only for a file an addon produced. Built from data- attributes the server
    // wrote, exactly like every other entry here, so this controller cannot get the path shape wrong
    // and a surface that omits them simply has no entry.
    //
    // BOTH ATTRIBUTES COME FROM ONE SERVER-SIDE HASH (AddonOrigins#addon_origins_for), so a cell
    // carrying the url always carries the label too. The `||` below is therefore NOT a live branch
    // today — it is there so a future surface that writes only the url gets a usable entry instead
    // of one reading "undefined", which is what `textContent = undefined` renders.
    const addonUrl = cell.dataset.addonOpenUrl
    if (addonUrl) {
      const edit = document.createElement("a")
      edit.href = addonUrl
      edit.textContent = cell.dataset.addonOpenLabel || "Edit in its generator"
      this.add(edit)
    }

    // DELETE IS LAST AND IS THE ONLY DESTRUCTIVE ITEM — last so a mis-aimed click lands on
    // something recoverable, and `.danger` so it does not read as one more navigation (that class
    // has its own rule in components.css; without one it would style nothing at all).
    //
    // A REAL DELETE WITH THE CSRF TOKEN, NOT A LINK. The menu is built in JS, so there is no
    // `button_to` to lean on and it has to assemble the request itself: a hidden `_method` for
    // Rack::MethodOverride and the token from the layout's own meta tag. `form.submit()` rather than
    // `requestSubmit()` deliberately — submit() fires no `submit` event, so Turbo does not intercept
    // it and this is a plain browser navigation ending at #destroy's redirect.
    //
    // `confirm` FIRST, with the wording the list row's `button_to` and the file page's button
    // already use, so the three delete doors ask one question — a fourth phrasing for one action is
    // exactly the divergence this menu exists to close. A cell may carry that question whole, as
    // `data-delete-confirm` written by the same helper that writes the row's (a folder's is wider
    // than a file's: it takes everything inside); without one it is "Delete NAME?".
    // `dataset.nodeName` reads `data-node-name`; it is NOT the DOM's `nodeName`, because `dataset`
    // is a DOMStringMap and has no such property.
    if (deleteUrl) {
      const name = cell.dataset.nodeName || "this item"
      const question = cell.dataset.deleteConfirm || `Delete ${name}?`
      const del = document.createElement("button")
      del.type = "button"
      del.className = "danger"
      del.textContent = "Delete"
      del.addEventListener("click", (e) => {
        e.stopPropagation()
        this.closeMenu()
        if (!window.confirm(question)) return this.returnFocus()
        const form = document.createElement("form")
        form.method = "post"
        form.action = deleteUrl
        form.innerHTML =
          `<input type="hidden" name="_method" value="delete">` +
          `<input type="hidden" name="authenticity_token" value="${document.querySelector('meta[name="csrf-token"]')?.content || ""}">`
        document.body.appendChild(form)
        form.submit()
      })
      this.add(del)
    }
    document.body.appendChild(this.menu)
    this.items()[0]?.focus()
  }

  add(item) {
    item.setAttribute("role", "menuitem")
    item.tabIndex = -1
    this.menu.appendChild(item)
  }

  items() {
    return this.menu ? Array.from(this.menu.querySelectorAll("[role='menuitem']")) : []
  }

  // The menu's own keys. Escape is the document listener's (it also closes the note popover).
  navigate(e) {
    const items = this.items()
    const at = items.indexOf(document.activeElement)
    const move = (i) => { e.preventDefault(); items[(i + items.length) % items.length]?.focus() }
    switch (e.key) {
      case "ArrowDown": return move(at + 1)
      case "ArrowUp": return move(at < 0 ? items.length - 1 : at - 1)
      case "Home": return move(0)
      case "End": return move(items.length - 1)
      case "Enter":
      case " ":
        // ONE ACTIVATION FOR EVERY ENTRY. A button activates on Enter and Space natively and a link
        // on Enter only; preventing the default and clicking makes Space work on a link too, and
        // makes each entry run through the same click listener a pointer runs through.
        if (at < 0) return
        e.preventDefault()
        e.stopPropagation()
        return items[at].click()
      case "Tab":
        // Closes, and lets the Tab carry on from the row — not from <body>, where focus would land
        // once the focused item is removed.
        this.closeMenu()
        return this.returnFocus()
    }
  }

  returnFocus() {
    const to = this.returnTo
    if (to?.isConnected) to.focus()
  }

  openPopover(noteUrl, x, y) {
    this.closePopover()
    const pop = document.createElement("div")
    pop.className = "note-popover"
    pop.style.left = `${x}px`
    pop.style.top = `${y}px`
    pop.addEventListener("click", (e) => e.stopPropagation())
    pop.innerHTML = `
      <textarea rows="3" placeholder="Add a note…" aria-label="Note"></textarea>
      <div class="note-popover-actions">
        <button type="button" data-role="save" class="btn small">Save</button>
        <button type="button" data-role="cancel" class="linkbtn">Cancel</button>
        <span class="note-popover-status" role="status"></span>
      </div>`
    const ta = pop.querySelector("textarea")
    pop.querySelector('[data-role="cancel"]').addEventListener("click", () => { this.closePopover(); this.returnFocus() })
    pop.querySelector('[data-role="save"]').addEventListener("click", () => this.save(noteUrl, ta.value, pop))
    document.body.appendChild(pop)
    this.popover = pop
    ta.focus()
  }

  async save(noteUrl, body, pop) {
    if (!body.trim()) return
    const status = pop.querySelector(".note-popover-status")
    status.textContent = "Saving…"
    let res, data
    try {
      res = await fetch(noteUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ note: { body } })
      })
      data = await res.json().catch(() => ({}))
    } catch (_e) {
      status.textContent = "Not saved: the server could not be reached. Try again."
      return
    }
    // The notes endpoint's refusal is a sentence written for a maker (a validation message); a bare
    // status from something in front of Rails is not, so it is not shown.
    if (!res.ok) {
      status.textContent = data.error ? `Not saved: ${data.error}` : "Not saved. Try again in a moment."
      return
    }
    window.location.reload()
  }

  closeMenu() { this.menu?.remove(); this.menu = null }
  closePopover() { this.popover?.remove(); this.popover = null }
  close() { this.closeMenu(); this.closePopover() }
}

// The cells that carry a menu: the payload's `data-action` names this door
// (FilesHelper#file_menu_data / #folder_menu_data), whatever else it also names.
const MENU_CELL = "[data-action~='contextmenu->filemenu#open']"
const FOCUSABLE = "a[href], button, [tabindex]"

function hasMenu(cell) {
  return !!(cell.dataset.noteUrl || cell.dataset.deleteUrl)
}

function pointerInside(cell, event) {
  if (!event.clientX && !event.clientY) return false
  const r = cell.getBoundingClientRect()
  return event.clientX >= r.left && event.clientX <= r.right && event.clientY >= r.top && event.clientY <= r.bottom
}

function belowOf(cell) {
  const r = cell.getBoundingClientRect()
  return { x: r.left + window.scrollX, y: r.bottom + window.scrollY }
}
