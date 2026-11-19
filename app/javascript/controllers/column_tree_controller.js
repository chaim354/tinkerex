import { Controller } from "@hotwired/stimulus"

// THE LIBRARY COLUMN'S FOLDER TREE (Shop manual spec §9; layouts/column/_library, ShellHelper#folder_tree_item),
// on the Folders group. A folder with subfolders carries a disclosure button; a press opens or closes
// its level and remembers the choice.
//
// OPENING: the server drew an open folder's level already (the chain to the folder on screen, and
// every folder the cookie names). A closed folder's level is an empty, hidden frame naming where its
// rows come from (`data-src`); the first open sets the frame's `src` and Turbo loads it
// (LibraryBrowseController#tree). Closing only hides the frame, so opening again costs nothing.
//
// REMEMBERING: the `library_tree` cookie holds the open folders' ids, oldest first, dot-separated,
// the newest MAX of them, so the server renders the next page with them open in its first byte: the
// theme cookie's shape (theme_controller.js; design-system.md rule 7), never a script before paint.
// The server reads it back through Maker::FolderTree.open_ids, which trusts nothing beyond the
// same well-formed ids (ID mirrors FolderTree::ID; an id outside it is simply not remembered).
const COOKIE = "library_tree"
const MAX = 50
const ID = /^[A-Za-z0-9_-]{1,64}$/

export default class extends Controller {
  toggle(event) {
    const button = event.currentTarget
    const open = button.getAttribute("aria-expanded") !== "true"
    button.setAttribute("aria-expanded", String(open))
    const frame = document.getElementById(button.getAttribute("aria-controls"))
    if (frame) {
      frame.hidden = !open
      if (open && !frame.hasAttribute("src") && frame.dataset.src) frame.src = frame.dataset.src
    }
    remember(button.dataset.folderId, open)
  }
}

// THE ONE WRITE PATH for the cookie: the id moved to the newest end when opened, removed when closed.
function remember(id, open) {
  if (!ID.test(id || "")) return
  const ids = openIds().filter((other) => other !== id)
  if (open) ids.push(id)
  const kept = ids.slice(-MAX)
  const age = kept.length ? 31536000 : 0
  document.cookie = `${COOKIE}=${kept.join(".")}; path=/; max-age=${age}; samesite=lax`
}

function openIds() {
  const pair = document.cookie.split("; ").find((part) => part.startsWith(`${COOKIE}=`))
  if (!pair) return []
  return pair.slice(COOKIE.length + 1).split(".").filter((id) => ID.test(id))
}
