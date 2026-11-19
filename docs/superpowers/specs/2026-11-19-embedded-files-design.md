# Embedded files: live HTML and a File block on the project page

Date: 2026-11-19. Asked for: "the ability to have embedded html files — for example the custom viewer
from pc case — and on the project page an option to have an embedded editor/viewer for a spreadsheet
or doc."

The motivating file is `Projects/pc case/out/viewer/walnut-pc-case.html`: a 4.2 MB self-contained
three.js viewer that loads three.js from cdnjs and jsdelivr and its fonts from Google Fonts.

## Decisions the owner made

1. **What an embed is:** a file from the library. One new content-block kind, **File**, shows that
   file's viewer inline on the project page, editable wherever the file page already allows editing.
   Not a database-native doc, not a Google/Office link.
2. **Docs are Markdown and text only.** No `.docx` or other new document format.
3. **Public pages show embeds read-only.** An `.xlsx` shows the public file page's download fallback,
   because that is what the public file page shows.
4. **HTML runs on a sandboxed route on the same host** (section 1 of the brainstorm, approved), not on
   a second hostname and not through `srcdoc`.

## 1. The sandbox door — `GET /sandbox/:token/*path`

User HTML runs scripts. At the app's own origin it would be stored XSS, which is why
`FileDelivery::SAFE_INLINE_TYPES` refuses `text/html`. The door is `SandboxController`, standing on
`ActionController::Base` like `Public::`, reading no session.

- **The token is the credential, never the session cookie.** A sandboxed document has an OPAQUE
  origin, and the browser sends no `SameSite=Lax` cookie with the requests it makes, so a
  cookie-checked door would serve the HTML and then refuse every file it loads. The token is signed
  (`ActiveSupport::MessageVerifier`, purpose `html_sandbox`, URL-safe) and expires in 12 hours; it names
  the owner, the HTML file's node, and — on a public page — the project. `Maker::HtmlSandbox` mints and
  reads it; every page render mints a fresh one.
- **`*path` is resolved against the HTML file's own folder**, through the catalog by parent edge and
  name (chunk_remote nodes have no `storage_path`): the folder itself and below, never above. A `..`, an
  empty segment or any segment starting with `.` is REFUSED, never normalised (`key_for`'s rule) — that
  also keeps `.git`, `.trash` and dot-files out. So `<script src="app.js">` beside the file works, not
  only a self-contained file.
- **A public token re-asks `Maker::PublicProject#permits?` for every file it serves**, and the project
  must still be published: a page that unpublishes stops serving within one request, not twelve hours.
- **Bytes go through the port's `read`, on every backend**, gated on the catalog's size (32 MB) before
  any read. The s3 delivery is a redirect to the bucket, and a redirect cannot carry the headers below;
  relative paths would also resolve against the bucket's key, not the library folder.
- **Every response carries an ENFORCING `Content-Security-Policy` whose `sandbox` directive omits
  `allow-same-origin`.** Report-only would not do: browsers ignore `sandbox` in a report-only policy.
  The app's global (report-only) policy is switched off on this controller so it does not report every
  CDN load. The header makes the document opaque-origin even when its URL is opened in a tab directly.
  Beside it: `Referrer-Policy: no-referrer` (the token is in the URL and must not reach cdnjs or Google
  Fonts in a `Referer`), `X-Content-Type-Options: nosniff`, `Cache-Control: private, no-cache` with the
  content token as the ETag.
- **The `<iframe>` carries the same `sandbox` attribute**, so the frame is sandboxed even before the
  response arrives. Granted: scripts, forms, modals, popups (escaping the sandbox, for outbound links),
  downloads, pointer lock. **Never `allow-same-origin`** — that one token undoes the isolation.

## 2. HTML on the file page

`Maker::FileAttachment::HTML_EXTS` (`html`) is a DISPLAY subset of the `code` role, the shape
`MARKDOWN_EXTS` already has; nothing is added to `ROLE_BY_EXT`, so filing is unchanged (`.htm` has no
role and is deliberately not given one here — a role moves files on the NAS). An HTML file's page opens
on a **Rendered** pane (the sandboxed frame, `files/viewers/_html`) with **Source** one press away — the
same toggle Markdown's page has, reusing `markdown_view_controller.js`. Source is the existing code
viewer or editor, by the existing editability rule. The public file page gets the same toggle with a
public token.

## 3. The File block

`Maker::ProjectBlock::KINDS` gains `file`: a `node_id` (required) and an optional `heading`. The layout
draft names it by node id, the YAML by path under the project folder (`file:`), exactly as an image
block does, against a map of all the folder's files. The editor picks it from a `<select>` of the
folder's files by path.

Rendered on the maker's page:

- **An HTML file** → the sandboxed frame directly, with an owner token.
- **Any other file** → a same-origin `<iframe>` of **`/files/:id/embed`**, a bare page (`layouts/embed`,
  `<base target="_top">`) holding exactly what the file page's preview area holds: the viewer chain,
  the Markdown/HTML toggles, the editor when the file page would offer one, the spreadsheet grid with
  Save. One viewer, never a second copy of it, and the project page pays no stat or read per block.
- Both have the heading (or the file name) linking to the file page, and a fixed, resizable height.

On a visitor's page the node must pass `pub.shown?`; an HTML file gets the frame with a public token,
anything else a frame of the public file page's bare variant (`/u/:handle/:slug/files/:id/embed`),
read-only, whose chain is the public file page's own (extracted to `public/files/_viewer`).

## Out of scope

`.docx` and other document formats; Google/Office URL embeds; a separate user-content hostname;
editing on a public page; serving files from outside the HTML file's folder.

## Testing

Request tests for the door (owner and public tokens, a tampered or expired token, `..` and dot-segment
refusals, a sibling asset, a file outside the folder, an unpermitted public asset, an unpublished
project, the size gate, and every header), mutation-checked; the file page's Rendered/Source toggle; the
embed pages; the block's model, document, editor and both renderings; and a system test that the
sandboxed frame really is opaque-origin (its script cannot reach the parent or read a cookie). All three
backend legs.
