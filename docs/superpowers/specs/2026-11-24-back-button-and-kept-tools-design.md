# One Back button, and tools that keep their place

2026-11-24. Two requests from the owner, decided in one conversation:

1. "Make back button have consistent behaviors and move or get rid of any back button on right of
   page."
2. "Tools should have some permanence so you can jump back and forth when working on it so should
   keep all its values for 15 minutes of away from that page time."

## What was there

- **One real Back button**, on the file page, at the right of the page head between Download and
  Delete. Its target was the request's referer (`ApplicationHelper#back_target_path`), which is the
  page that LINKED here, not the page the maker was on: two files that link to each other bounce
  between themselves, and a redirect back to the same page drops it to the Library root.
- **The folder chooser's "← Back"** sat at the right of the dialog's footer beside Cancel and Choose.
- **The Box Generator and OpenSCAD bundles** each draw their own "Back" at the right of their page
  head, which returns to the tool's gallery (`chaim354/tinkerex-addons`).
- **A tool kept nothing.** Leaving an add-on page disconnected `addon_controller.js`, which tore the
  host down; returning mounted the bundle again from its defaults. The Material estimate is a
  stateless form and came back empty.

## Decisions (the owner's)

- Back lives in the **top bar, far left, on every signed-in page**.
- A tool is **kept alive in memory**, not serialised: the live DOM and its JavaScript state are held
  for 15 minutes, so every field, the open generator, a loaded file, the preview and undo come back.
  A browser reload or a new tab starts fresh; that was the stated trade.

## Back

`layouts/_topbar` renders one `a.topbar-back` before the breadcrumb, `back_controller.js` on it.

- **A click goes back one step in this tab's history** (`history.back()`), exactly what the browser's
  Back does, so the page returns as it was left: scroll, filter, open folder, a kept tool.
- **Only when the previous entry is ours.** `navigation.currentEntry.index > 0` where the Navigation
  API exists (its entries are same-origin by definition), else Turbo's own
  `history.state.turbo.restorationIndex > 0`. A modified click (new tab) is left to the browser.
- **Otherwise the link's `href` is followed**, and the server fills it: the referer when it is ours
  and not this page (`back_target_path`, unchanged), else one level up — the last link of the page's
  breadcrumb — else Recent. On Recent with nothing behind it the control is `aria-disabled`.
- The file page's own Back is removed. `back_target_path` stays: three redirects use it.
- The chooser's "← Back" moves to a bar at the left of its path, as the inline browser has it. It is a different verb (pop one column
  inside a dialog) and keeps its name there; nothing on a page's right says Back any more.
- The bundles' in-tool Back becomes a named control at the left, above the title ("← All
  generators", in both bundles): it goes up inside the tool, which the top bar's Back does not.
  `chaim354/tinkerex-addons`, branch `claude/in-tool-back-left`; the host's boxes fixture mirrors it.
- Named foot links ("Back to projects", "Back to Devices", "Back to publishing") and the welcome
  wizard's step buttons stay: design-system.md rule 9 already allows "Back to NAME".

## Kept tools

`lib/kept_tools.js` holds sessions in a module-level list, which survives Turbo visits because the
document does.

- **A session is `{ tool, url, owner, node, release, expiresAt }`.** `node` is the live subtree,
  detached; `release` is what ends it for good (an add-on: the host's teardown handlers).
- **Kept on disconnect, taken on connect.** Leaving the page detaches the live subtree and leaves a
  dead clone in its place, so Turbo's snapshot of the page is what it would have been anyway.
  Returning swaps the live subtree back in before the first paint.
- **One session per tool, and which visit resumes it:** the tool is its page's path. A visit to the
  URL the session was kept under resumes it, and so does the tool's plain URL (no query), which
  returns to whatever the tool was last doing. A link naming a different saved item, file or folder
  mounts fresh AND ENDS the kept session: a bundle is an ES module evaluated once per page, so two
  live mounts of one tool would share its module-level state. (The first draft kept both; that is
  why it does not.)
- **15 minutes from leaving**, by a timer and re-checked against the clock on return (a sleeping
  laptop delays timers). Each leaving starts them again. At most five sessions; the oldest goes
  first.
- **Never across accounts.** A session records the signed-in user's marker and a mismatch discards
  it; submitting a sign-out form discards them all.
- **A Turbo preview never takes or keeps a session, and a page that keeps a tool asks for none**
  (`turbo-cache-control: no-preview`). The preview of a tool page is an inert copy holding an
  earlier visit's values; it flashed them before a fresh mount, which first showed up as a flaky
  test reading one account's text on another account's page.
- **Add-ons:** the SDK gains `suspendHost(instance)`, `resumeHost(instance)` and
  `endHost(instance)`. A suspended host is not torn down and stays bound until another tool binds
  its own, so a kept tool's in-flight request finishes against its own host. A resumed host comes
  back with the context it was served: refreshing the page-bound parts (the CSRF token, the two
  choosers) was written, had no observable effect, and was removed. No capability changes and
  `Host::LEVEL` does not move: a bundle sees nothing new.
- **Material estimate:** `keep_controller.js` on a wrapper keeps the form's subtree the same way.
  Turbo sends the page's own CSRF token as a header, so the kept form's hidden token is not what
  authorises a later submit.
- **A resumed tool says so**: "Picked up where you left off. Start over" under the page head. Start
  over discards the session and loads the page again.

- **The two "Search everything" forms are Turbo visits.** They carried `turbo: false` with no reason
  recorded, and the box is on every page: a search from a tool's page loaded a new document, which
  emptied the memory the tool is kept in. Found after the first full run, by listing what still
  loads a page.

### Known costs

- A page load starts a tool fresh: a reload, a new tab, and the forms that still submit with
  `turbo: false` (upload, New folder, rename or move, pin, rescan, attach). The browser's Back
  usually restores the old document.

- A kept tool goes on running: OpenSCAD's viewer keeps its animation frame loop for up to 15
  minutes. A `suspend` event for bundles would end that and is not built.
- A kept add-on keeps the context it was served: its folder list is as old as the session.

## Tests

- `test/integration/web/topbar_back_test.rb`: the href's three sources, the disabled state, no
  cross-origin referer, none on a signed-out page; the file page head holds no Back.
- `test/system/topbar_back_test.rb`: a click returns to the previous page without a new history
  entry (the bounce), a fresh tab follows the href.
- `test/system/kept_tools_test.rb`: an add-on comes back as the same elements with its host alive;
  the Material estimate's parts and numbers; Start over; expiry; another account; sign-out; a
  different deep link mounts fresh. Every return is a Turbo visit.
- `test/system/box_save_folder_test.rb`: the real Box Generator editor kept, and its way up to the
  gallery at the left.
- `test/system/file_chooser_test.rb`: Back sits at the left of the dialog, ahead of the path.
