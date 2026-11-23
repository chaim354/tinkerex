import { Controller } from "@hotwired/stimulus"

// Right-click a tool → "Pin to sidebar" or "Unpin from sidebar" (2026-10-22), and on an addon's card
// in the Tools gallery, "Permissions…" (2026-11-23). On every card in the gallery and on each pinned
// tool's link in the rail; Tools::PinsController does the pinning and redirects back, so the sidebar
// the maker sees afterwards is the server's. THIS MENU IS THE ONLY WAY TO PIN A TOOL since the cards'
// visible Pin toggle was removed (2026-11-23, the owner's call), and the only way to a tool's
// permissions from the gallery; its own page lists them too (tools/addons/show).
//
// EVERY VALUE COMES FROM A `data-` ATTRIBUTE THE SERVER WROTE (ShellHelper#tool_menu_data), as in
// filemenu_controller.js: the pin URL, whether the tool is pinned, its name, and the id of its
// permissions <dialog> (tools/home/_permissions_dialog, rendered at the foot of the gallery). A cell
// with neither a pin URL nor a dialog is not this menu's, and the browser's own menu appears.
//
// THE MENU WEARS `.file-menu`, the app's one right-click menu face (components.css), so the two
// menus look and behave alike: an outside click or Esc closes it. It takes focus when it opens, so
// a menu opened from the keyboard (the context-menu key, Shift+F10) can be used from the keyboard,
// and Esc hands focus back to the tool it was opened on — as closing the permissions dialog does.
export default class extends Controller {
  connect() {
    this.onDocClick = () => this.close()
    this.onKey = (e) => {
      if (e.key !== "Escape" || !this.menu) return
      this.close()
      this.opener?.focus()
    }
    // A SNAPSHOT TAKEN WITH THE DIALOG OPEN WOULD COME BACK OPEN, as a plain in-flow <dialog open>
    // with no backdrop and no inert page, on Back. Closing it before Turbo caches the page is what
    // the calculator's modal does for the same reason (layouts/_calculator).
    this.onBeforeCache = () => {
      this.close()
      this.element.querySelectorAll("dialog[open]").forEach((dialog) => dialog.close())
    }
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    this.close()
  }

  // data-action="contextmenu->toolmenu#open" on each tool.
  open(event) {
    const cell = event.currentTarget
    const url = cell.dataset.toolPinUrl
    const dialog = cell.dataset.toolPermissions && document.getElementById(cell.dataset.toolPermissions)
    if (!url && !dialog) return
    event.preventDefault()
    // ONE MENU ON THE PAGE. The gallery and the rail each mount this controller, and a contextmenu
    // event is not a click, so the other one's document listener would leave its menu standing.
    document.querySelectorAll("[data-toolmenu-menu]").forEach((menu) => menu.remove())
    this.close()

    // Where Esc returns focus: the tool itself when it is a link (the rail's), else the control
    // inside it. A card is a <div>, which cannot take focus; its title — a link, or the
    // calculator's <button> — can.
    this.opener = cell.matches("a, button") ? cell : cell.querySelector("a, button") || cell
    this.menu = document.createElement("div")
    this.menu.className = "file-menu"
    this.menu.dataset.toolmenuMenu = ""
    this.menu.setAttribute("role", "menu")
    this.menu.setAttribute("aria-label", cell.dataset.toolName || "Tool")
    this.menu.style.left = `${event.pageX}px`
    this.menu.style.top = `${event.pageY}px`

    if (url) {
      const pinned = cell.dataset.toolPinned === "true"
      this.addItem(pinned ? "Unpin from sidebar" : "Pin to sidebar", () => this.submit(url, pinned ? "delete" : "post"))
    }
    if (dialog) {
      const opener = this.opener
      this.addItem("Permissions…", () => this.showPermissions(dialog, opener))
    }
    document.body.appendChild(this.menu)
    this.menu.querySelector("button").focus()
  }

  addItem(label, run) {
    const item = document.createElement("button")
    item.type = "button"
    item.setAttribute("role", "menuitem")
    item.textContent = label
    item.addEventListener("click", (e) => {
      e.stopPropagation()
      this.close()
      run()
    })
    this.menu.appendChild(item)
  }

  // showModal() puts the dialog in the top layer and makes the page inert; the browser moves focus
  // into it (the × is its first control). Where focus goes when it shuts is `dialogClosed`'s.
  showPermissions(dialog, opener) {
    this.dialogOpener = opener
    dialog.showModal()
  }

  // data-action="close->toolmenu#dialogClosed" on each permissions dialog — whichever way it
  // closed: Esc, the ×, or the backdrop. The menu item that opened it has gone with the menu, so
  // the browser's own focus restoration would land on <body>; the card's title link is the tool.
  dialogClosed() {
    this.dialogOpener?.focus()
    this.dialogOpener = null
  }

  // data-action="click->toolmenu#backdrop". A click on the ::backdrop is a click on the <dialog>
  // itself, outside its box — the calculator's test (calculator_controller.js#backdrop). EACH HALF
  // COVERS WHAT THE OTHER CANNOT, though a mouse click on the content satisfies both, so removing
  // either alone leaves tool_permissions_test.rb green (measured): the target check keeps a click
  // the keyboard synthesises on a control inside (clientX/Y 0, "outside" the box) from closing it,
  // and the box check keeps a click on the dialog's own edge or scrollbar (target: the dialog) open.
  backdrop(event) {
    const dialog = event.currentTarget
    if (event.target !== dialog) return
    const box = dialog.getBoundingClientRect()
    const inside = event.clientX >= box.left && event.clientX <= box.right &&
                   event.clientY >= box.top && event.clientY <= box.bottom
    if (!inside) dialog.close()
  }

  // A REAL POST OR DELETE WITH THE CSRF TOKEN, assembled here because the menu is built in JS and
  // has no `button_to` to lean on — filemenu_controller.js#open's Delete, for the same reasons.
  // `form.submit()`, not `requestSubmit()`: no `submit` event, so Turbo stays out of it and this is a
  // plain navigation ending at the controller's redirect.
  submit(url, method) {
    const form = document.createElement("form")
    form.method = "post"
    form.action = url
    const token = document.querySelector('meta[name="csrf-token"]')?.content || ""
    form.innerHTML =
      (method === "delete" ? `<input type="hidden" name="_method" value="delete">` : "") +
      `<input type="hidden" name="authenticity_token" value="${token}">`
    document.body.appendChild(form)
    form.submit()
  }

  close() {
    this.menu?.remove()
    this.menu = null
  }
}
