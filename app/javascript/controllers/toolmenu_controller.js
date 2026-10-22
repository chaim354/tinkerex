import { Controller } from "@hotwired/stimulus"

// Right-click a tool → "Pin to sidebar" or "Unpin from sidebar" (2026-10-22). On every card in the
// Tools gallery and on each pinned tool's link in the rail; Tools::PinsController does the work and
// redirects back, so the sidebar the maker sees afterwards is the server's.
//
// EVERY VALUE COMES FROM A `data-` ATTRIBUTE THE SERVER WROTE (ShellHelper#tool_menu_data), as in
// filemenu_controller.js: the URL, whether the tool is pinned, and its name. A cell without a URL is
// not this menu's, and the browser's own menu appears.
//
// THE MENU WEARS `.file-menu`, the app's one right-click menu face (components.css), so the two
// menus look and behave alike: an outside click or Esc closes it. It takes focus when it opens, so
// a menu opened from the keyboard (the context-menu key, Shift+F10) can be used from the keyboard,
// and Esc hands focus back to the tool it was opened on.
export default class extends Controller {
  connect() {
    this.onDocClick = () => this.close()
    this.onKey = (e) => {
      if (e.key !== "Escape" || !this.menu) return
      this.close()
      this.opener?.focus()
    }
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
    this.close()
  }

  // data-action="contextmenu->toolmenu#open" on each tool.
  open(event) {
    const cell = event.currentTarget
    const url = cell.dataset.toolPinUrl
    if (!url) return
    event.preventDefault()
    // ONE MENU ON THE PAGE. The gallery and the rail each mount this controller, and a contextmenu
    // event is not a click, so the other one's document listener would leave its menu standing.
    document.querySelectorAll("[data-toolmenu-menu]").forEach((menu) => menu.remove())
    this.close()

    const pinned = cell.dataset.toolPinned === "true"
    // Where Esc returns focus: the tool itself when it is a link, else the control inside it (the
    // calculator's card is a <div>, which cannot take focus, and its Open button can).
    this.opener = cell.matches("a, button") ? cell : cell.querySelector("a, button") || cell
    this.menu = document.createElement("div")
    this.menu.className = "file-menu"
    this.menu.dataset.toolmenuMenu = ""
    this.menu.setAttribute("role", "menu")
    this.menu.setAttribute("aria-label", cell.dataset.toolName || "Tool")
    this.menu.style.left = `${event.pageX}px`
    this.menu.style.top = `${event.pageY}px`

    const item = document.createElement("button")
    item.type = "button"
    item.setAttribute("role", "menuitem")
    item.textContent = pinned ? "Unpin from sidebar" : "Pin to sidebar"
    item.addEventListener("click", (e) => {
      e.stopPropagation()
      this.close()
      this.submit(url, pinned ? "delete" : "post")
    })
    this.menu.appendChild(item)
    document.body.appendChild(this.menu)
    item.focus()
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
