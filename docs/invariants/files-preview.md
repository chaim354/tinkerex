# The file-type vocabulary and the preview surfaces

§14d/§14b material for the Files pages, the preview renderers and the thumbnail poll. Moved out of
CLAUDE.md on 2026-08-26 because it binds inside one subsystem and was being skimmed on every
unrelated session. Read this before touching `app/models/maker/file_attachment.rb`,
`app/services/maker/previews/`, `FilesController#preview_kind`/`#index`/`#thumbnails`,
`app/views/files/`, `app/javascript/controllers/thumbs_controller.js`, or `Node`'s display scopes.

## ONE file-type vocabulary, and it reaches the RENDERERS too

`FilesHelper::EXT_FAMILIES` is **derived** from `ROLE_BY_EXT`. `FilesController#preview_kind`'s
`:text` branch and `Maker::Previews::Registry`'s TextThumb entries are **both**
`Maker::FileAttachment.text?` / `TEXT_EXTENSIONS`. **Add an extension in `ROLE_BY_EXT` only.**

The Registry hand-listed **4** text extensions while `preview_kind` called **37** text, so 33 of
them (`.rb`, `.py`, `.gcode`, `.yml`, `.csv`, `.scad`, every `.c` and `.h`) got the source viewer
and a **blank grid cell** — `Enqueue.call` returns nil for a name no renderer claims, so no row is
ever created. No test spanned the two layers; each table looked right alone.

**STAGE 3, S3-1: `ROLE_BY_EXT` IS NOW THE SEED OF THE FILING MAP, NOT THE FILING MAP ITSELF.**
`Maker::ProjectFolders.folder_for(user, name)` no longer answers straight out of `ROLE_BY_EXT` +
`ROLE_FOLDERS` — it reads `Maker::FilingRules.for(user)`, a per-user table seeded ONCE from those
two (`ROLE_BY_EXT`'s extension → role → `ROLE_FOLDERS`'s role → folder) on a user's first read, then
edited at `/settings/filing`. That does not loosen this file's own rule: an extension still needs a
`ROLE_BY_EXT` entry to be SEEDED with any folder at all (an extension nobody has wired stays
answerable only as `"other"`, the fallback every per-user row lookup shares), so "add an extension
in `ROLE_BY_EXT` only" is still where a new extension's file-type identity is decided — it is only
the FILING destination that a user may now override afterward. `default_folder_for(name)` is the
old pure function preserved verbatim (no user, no override) for the seed's own use and for a
caller with no user in hand.

Two consequences of the one table:

- Every extension must satisfy `FilesController::EXT_RE` (`/\A[a-z0-9]{1,8}\z/`) or it renders a
  filter chip that links and **silently does nothing**. `markdown` is the bound, at exactly 8.
- The `role` column is **behavioural** — cover-image selection reads `image`/`model`, and
  `Models::AttachmentsController` dispatches `ExtractPdfMetadataJob` on `instructions`, so `pdf`
  must stay `instructions`. A third copy in `importer_controller.js`'s `roleFor` has drifted; it is
  browser-only and the server re-derives authoritatively.

## Extensionless text is a SEPARATE AXIS, and it must not move files

`File.extname("LICENSE")` is `""`, and so is `File.extname(".gitignore")` — a leading dot with no
second dot is not an extension. **No entry in an extension table can ever reach those files.**
`TEXT_BASENAMES` covers them, matched on the whole downcased basename (the live library holds both
`Makefile` and `makefile`, so downcasing is load-bearing).

`Registry.for_filename` falls back to it; **`Registry.for` deliberately does NOT** — that door takes
a raw extension, and teaching it to also answer for `"LICENSE"` lets a caller holding a genuine
extension match a basename by coincidence.

**It grants no ROLE, and that is the point.** `role_for("LICENSE")` stays `"other"`, so
`Maker::ProjectFolders` keeps filing it where it files it today. Giving it `document` would MOVE it
into `docs/` on the user's NAS — a change to their files, not to a preview. Same split `.scad`
carries: role answers *where a file lives*, content type answers *how it is shown*.

## `/files/thumbnails` MUST answer for a node with no row

This was `next unless p`, which **omits the key** — and `thumbs_controller`'s `if (!entry) continue`
then leaves that cell spinning **and in the poll set**, so it burns all 40 tries and the spinner
stays on screen for as long as the page is open. The animation is CSS; ending the poll does not end
it.

The failure was worked around **three times at the callers** (`files/_list`, `files/_grid`, and
`models/_hero_poster`, whose comment describes this exact loop) and was **still live** in
`projects/_attachment_group`. Answering at the endpoint fixes every caller at once — including
`projects/_card` and `models/_card`, which hold only a `cover_node_id` and so *cannot* guard
themselves.

**The two no-row cases are different questions and must stay so:**

| cause | answer | why |
|---|---|---|
| nothing will ever render this name, or the node is not live (a tombstone) | `unsupported` | terminal; the client resolves it to a static badge |
| the name IS renderable, the row merely does not exist yet | **omit** | `backfill: false` on this door means a row is genuinely still coming |

Collapsing them trades a hung spinner for a **wrong** one, which is worse because it looks correct.
`thumbs_controller` also resolves stragglers to badges when polling gives up, so "forever" is not
reachable even if the endpoint is wrong.

## Dot-files are a DISPLAY filter, never a scan skip

`Node.visible_entries(show_hidden)` hides dot-prefixed names; `FilesController#resolve_hidden`
persists the choice in a **cookie**, like `view` and `sort`, because folder links carry only
`folder:` and a param would die on the first navigation. `requested == "1"` is what makes the
control two-way — `?hidden=0` is `present?`, so a `params[:hidden].present?` spelling turns dot-files
on and can never turn them off.

**Never move this to the observer.** The instant a name becomes unobservable, a live node still
pointing there is a ghost the Reconciler can never pair, whose tombstone trips the mass-deletion
guard and refuses that scan **and every scan after it, permanently** (§14b; four wedges so far).
Hiding a row that still exists, still syncs and still attaches to projects is trivially reversible.

`.git` is a **separate rule** and stays hidden even with hidden files shown: `Library::RepoMetadata`
keeps the marker indexed as the evidence a directory is a working tree, and on share/s3 nothing
beneath it is observed, so revealing it offers a folder that cannot be opened usefully.

Both scopes go on `FilesController#index`'s `scope =` assignment, **not** the `.order` chain —
`@match_count`/`@child_count` read the same object, so one line lower the truncation banner and the
pager count rows the page never renders.
