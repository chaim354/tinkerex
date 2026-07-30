# The browser tier

A system test costs **~932 ms**; a unit test costs **~3.2 ms** (measured 2026-07-29: 6 system
examples in 5.59 s, 1628 unit tests in 5.16 s). That is a factor of **294**. Without a rule this
tier either stays at six tests forever or grows until it dominates the suite — so:

> **A behaviour earns a system test if and only if it is observable only in a browser.**

## Qualifies

- Stimulus controller logic — DOM reading/writing, event wiring, `data-*` value plumbing
- Form-control semantics. `<input type="text">` silently strips newlines, which broke five box
  generators (one of them *silently*) and no server-side test could see it. That bug is why
  `tray_layout_test.rb` exists.
- Turbo visits, redirects and reloads. `<head>` merging on a Turbo visit is why the sheet grid
  needed `data-turbo-track="reload"`, and a direct `visit` is the one path where that bug does
  **not** reproduce.
- Rendered-HTML → JS contracts: does the view actually emit the attribute the controller reads?

## Does not qualify — keep these at the request level

Authorisation, persistence, the `FileLayer` port, and backend selection. They have cheap coverage
already: `test/integration/web` is 31 files, and the ambient-backend risk is covered by `ci.yml`'s
three `LIBRARY_BACKEND` legs.

**Do not re-run the three-backend matrix through the browser.** Pin one backend per test with
`pin_file_layer_backend` and let the port's own contracts do their job.

## Every test here is mutation-checked

Revert the behaviour the test pins and confirm it goes red — then say so in a comment, naming what
you reverted. This repo has already been bitten by a hermetic fake that shared the code's
misunderstanding and hid a silent data-loss bug behind 79/80 green tests. A test nobody has watched
fail is a test nobody should trust.

**Clear the chunk store first, or a broken mutation can read GREEN.** `tmp/dev-chunks*` blobs outlive
`Storage::ChunkStore.reset!`, and because storage is content-addressed while SQLite reuses rowids
after a rolled-back transaction, a stale blob at the same `chunks/<user_id>/<hash>` key silently
satisfies a mutated run. This is not hypothetical — it made `uploader_test.rb`'s second mutation look
green until the directory was cleared:

```bash
rm -rf tmp/dev-chunks*
```

## Two environment traps that cost real time

**A Selenium file attach cannot read a fixture under a macOS-protected directory.** If the checkout
lives under `~/Desktop` (or Documents/Downloads), TCC gates it behind a per-app consent a *synthetic*
non-Finder attach never satisfies: Chrome accepts the attach, then `file.arrayBuffer()` throws
`NotReadableError`. Copy the fixture to a `Dir.mktmpdir` for the attach and assert against the
original. `uploader_test.rb` does this and explains it inline. It may not reproduce on the CI runner,
whose work dir is not under a protected directory — do it anyway.

**`attach_file`'s `make_visible:` takes `true` or a style Hash — never a selector String.** A String
is fed into a `for (var prop in css)` style-patch, silently iterates the string's character indices,
sets nothing, and then raises "The style changes in :make_visible did not make the file input
visible". The error names the symptom, not the cause, so this reads as a broken page.

## Honest limits are better than false coverage

`modelviewer_controller.js` renders into a `<canvas>`, which is opaque to Capybara. The right test
asserts it mounts, requests the model URL, and logs no console error — **not** that geometry
appeared. A test that looks like it checks the render while checking nothing is worse than no test.
