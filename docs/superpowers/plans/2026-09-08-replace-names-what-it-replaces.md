# A replace names the content it replaces (tinkerex#276) — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md`. ONE implementation task
> (the files are coupled by a kwarg), then one capped full-depth review that re-runs the mutations.

**Goal:** a browser save on share or s3 must refuse, not overwrite, when the file on the store has
changed since the editor rendered it — today `Maker::TextSave` compares the editor's token against
the CATALOG's row, which lags the store until the next scan, so a desktop edit made in between is
overwritten (measured in S4-4's review).

**Architecture:** the port's `write(replace: true)` gains an optional `expect_token:`. When given,
the adapter compares the STORE's current content identity against it before writing — Share hashes
the file on disk, S3 HEADs the object through the identity ladder — and raises a new
`FileLayer::StaleContent` (a subclass of `UnsupportedOperation`, §14a's rule for a caller that must
branch) without writing a byte. `Maker::Addons::LibraryOutput.write_bytes!` threads the kwarg through
and `Maker::TextSave` passes the editor's base token. **chunk_remote needs nothing**: its upload
already carries `base_version_id`, and the sync server records a CONFLICT on a stale base instead of
overwriting (`docs/sync-protocol.md`, "Last-writer-wins was false"); the mirror's staleness is then a
conflict row, never a lost edit — say so in the plan's docs step and change nothing there.

**Branch:** `claude/replace-names-its-base` off main. Rules that bind: CLAUDE.md §14a (the `replace:`
bullet — a replace reuses the node; clobber is `UnsupportedOperation`; `FetchError` is the retryable
answer and this is NOT retryable), §14b (share hashes are `Digest::SHA256.hexdigest`, the scan's own
spelling), §15 (mutation-check every guard), `docs/invariants/git-editing.md` (content against HEAD's
blob for git; this change is about the PORT write both doors share).

## Decisions

1. **The check is in the ADAPTER, not the door.** TextSave's header already says "closing the gap is
   a port question, not a door's": only the adapter knows what "current" means on its store (a
   sha256 of bytes on share, the ETag/checksum ladder on s3), and a door-side `read` + hash would be
   a second spelling of each.
2. **Share hashes every time; no mtime fast path.** A README is small, addon outputs are small, and
   `Digest::SHA256.file` streams; a fast path keyed on mtime+size would be a second definition of
   "changed" beside the scan's and could miss an edit that kept both.
3. **S3 is one HEAD per replace, not per read.** §14a refuses HEAD-per-object-per-scan; a HEAD on a
   user-initiated save is one billed request per save and is what makes the token comparable — the
   row's `content_hash` was minted by the same ladder (`ObjectIdentity.for`).
4. **`expect_token: nil` means "no check"** — every existing caller passes none and keeps today's
   behaviour; only TextSave opts in. A create (`replace: false`) ignores it.
5. **`StaleContent` is a SUBCLASS of `UnsupportedOperation`**, so a caller that does not branch still
   gets the 422 mapping, and TextSave, which must, rescues the subclass and answers STALE (409).

## File structure (one task)

- `app/services/file_layer/base.rb` (or wherever `UnsupportedOperation` is defined): `StaleContent`.
- `app/services/file_layer/share.rb`, `app/services/file_layer/s3.rb`: `write(..., expect_token: nil)`.
- `app/services/maker/addons/library_output.rb`: `write_bytes!(..., expect_token: nil)` threads it to `write`; the chunk_remote branch ignores it (comment says why).
- `app/services/maker/text_save.rb`: passes `expect_token: base_token` on the replace path; rescues `StaleContent` → `refusal(STALE)`; header rewritten (the "SEES THE CATALOG'S TOKEN" paragraph becomes "the catalog first, then the store").
- `test/services/file_layer/adapter_write_contract.rb`: two cases behind `port_writable?` — a matching token writes and keeps the node; a mismatched one raises `StaleContent`, writes nothing, keeps the store's bytes.
- `test/services/maker/text_save_test.rb`: on share, change the file on disk behind the catalog (write different bytes at `storage_path`, no scan), save with the rendered token → 409 STALE, the disk keeps the desktop edit; then a scan later reconciles (not asserted here).
- `test/integration/web/` — the README door and `FilesController#update` each get one request-level case of the same shape.
- `CLAUDE.md` §14a: the `replace:` bullet gains one sentence naming `expect_token:`/`StaleContent`.

## Steps

1. Read the two adapters' `write`, `LibraryOutput.write_bytes!` (both branches), `TextSave.call`, the write contract's replace tests and `text_save_test.rb`.
2. `StaleContent < UnsupportedOperation` beside its parent, with a one-line comment.
3. Share: after `existing = ...` and the clobber check, `if replace && expect_token && File.exist?(dest) && Digest::SHA256.file(dest).hexdigest != expect_token → raise StaleContent, "#{rel.inspect} changed since it was read"`. S3: same shape with `ObjectIdentity.for` over a HEAD (the same call `#stat`-refresh uses; presence-guard the etag as `#move` does).
4. LibraryOutput and TextSave: thread and rescue. TextSave's rescue is narrow (`StaleContent` only) — a clobber on the CREATE path stays the port's `UnsupportedOperation` the door already handles.
5. Tests, then mutations, each reported verbatim: (i) drop the Share check → the contract's mismatch case and the TextSave disk-edit case go red (an overwrite); (ii) drop the S3 check → the contract's s3 case goes red; (iii) make TextSave pass `expect_token: nil` → the disk-edit case goes red; (iv) rescue `UnsupportedOperation` instead of `StaleContent` in TextSave → the create-clobber test's message changes (report what happens).
6. Docs, commit (`-F`, pathspec), report. No `bin/ci`; the orchestrator runs the gates.
