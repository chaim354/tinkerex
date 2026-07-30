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

## Honest limits are better than false coverage

`modelviewer_controller.js` renders into a `<canvas>`, which is opaque to Capybara. The right test
asserts it mounts, requests the model URL, and logs no console error — **not** that geometry
appeared. A test that looks like it checks the render while checking nothing is worse than no test.
