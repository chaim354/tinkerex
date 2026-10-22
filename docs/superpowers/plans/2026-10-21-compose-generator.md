# A public, browser-only docker-compose generator — Implementation Plan

**Goal:** a prospective self-hoster opens `/install/compose`, fills in a short form (their folder or
SMB share, port, user, image tag, Tools on/off, mail), watches the `docker-compose.yml` update as they
type, and downloads or copies it. Everything happens in the browser: there is no `<form>`, no fetch,
nothing in a URL, so an SMB or SMTP password typed there never leaves the tab.

**Owner's request (2026-10-21, overnight program):** "Docker compose generator for tinkerex that is
local browser only that the user puts in the required info and it downloads the properly formatted
yml file", placed in "a public page in the app". Share backend only, matching #454.

**Worktree:** `.claude/worktrees/compose-generator-95dbc4`, branch `claude/compose-generator-95dbc4`.

---

## Architecture

```
docker-compose.yml ──read at render time──▶ Tinkerex::ComposeTemplate (Ruby)
                                              tree      the parsed YAML, ${VAR:-default} left in
                                              leading   comment lines that precede a key, by path
                                              trailing  comment lines that close a block, by path
                                              flow      paths written as [a, b] in the file
                                              tools     services the app names by URL, their env
                                                        keys, the named volumes only they mount
                                              share     the network-share switch: the bind target,
                                                        the volume name, its prose, and the
                                                        commented example parsed back to YAML
                                                  │
                     Public::ComposeController#show (sessionless) embeds it as a Stimulus value
                                                  │
              compose_controller.js ── reads the inputs ──▶ lib/compose_file.js
                                                              validate(choices)  → messages
                                                              generate(template, choices) → YAML
                                                  │
                                 preview <pre>, Download (Blob), Copy (copy_controller)
```

**The drift mechanism: the template IS the repo file, read at render time.** No second copy of the
compose file exists anywhere. A new environment variable, service setting or comment in
`docker-compose.yml` reaches the generator's output on the next render with no edit here. What the
generator knows by hand is small and each piece raises (and fails a test) when the file stops
matching it: the app service is `web`, the library is the bind mount whose target is `/library`, the
network share is the commented `library:` block at the end of the file, and a Tools service is one
the app's environment names by URL.

Three tests carry it:
1. `test/lib/tinkerex/compose_template_test.rb` — every comment line of the file is accounted for
   exactly once (header, leading, trailing, example, or a generator marker), every path exists in the
   tree, the Tools set equals `Tinkerex::Sidecars#names + addons` (the checkout's definition), and a
   file whose shape the derivation does not understand raises rather than guessing.
2. `test/system/compose_generator_test.rb` — **the drift guard proper**: the all-defaults output,
   Psych-parsed, equals `docker-compose.yml` with every `${VAR:-default}` resolved; the share output
   built from the commented example's own values equals that example uncommented; Tools off removes
   exactly the Tools services, env lines and volume. Plus the escaping matrix and validation.
3. `test/deploy_hygiene_test.rb` — `docker-compose.yml` survives `.dockerignore` (it did not: the
   image excluded `/docker-compose*.yml`, so reading it at render time would have been a production
   500 behind a green suite), and the two overlays still do not.

## Decisions made without the owner

1. **Route `/install/compose`, controller `Public::ComposeController`.** The `Public::` namespace
   gives the sessionless guard (`architecture_invariants_test.rb` scans its controllers and views)
   and the visitor shell for everyone, signed in or not, which is what a page about installing needs.
   The public header's intro line takes a `content_for(:public_intro)` override; nothing else in the
   header changes.
2. **SMB only — no NFS.** The brief listed NFS fields, but neither `docker-compose.yml`'s commented
   `library` block nor INSTALL.md describes NFS, and the brief also says "don't invent knobs". Adding
   NFS means adding it to the compose file and INSTALL.md first; the generator then needs the second
   example. Question for the owner.
3. **Every value is inlined**, including the ones the form does not ask for (`RAILS_MAX_THREADS` 16):
   the output is one self-contained file. `env_file: .env` stays, so a `.env` still adds container
   environment. The repo file's header (which explains `.env` overrides for values the generated file
   has inlined) is replaced by a generated one; every other comment is carried over where its key is,
   and the two `bin/rails generate sidecar` marker comments are dropped (they are instructions to a
   repo tool, not to an installer).
4. **In share mode the SMB `uid`/`gid` follow PUID/PGID** (else the example's 1000/1000): INSTALL.md
   says those options make the share's files belong to the user the app runs as, so they must agree.
   The volume's leading comment and `LIBRARY_HOST_PATH` (display-only) become the share's address, as
   INSTALL.md §3 step 3 suggests.
5. **The image tag applies to the app image only.** The Tools images are versioned in their own repos
   and stay `:latest`.
6. **Accounts/mail:** the `SMTP_*`, `APP_HOST` and `MAIL_FROM` knobs of INSTALL.md §4, plus
   `FORCE_SSL` (in `.env.example`, and it decides whether mail links are https). `REGISTRATION` is not
   offered — `closed` is the only value the share backend boots with. `DEMO_ACCOUNT_EMAIL`,
   `LIBRARY_TRASH_DAYS`, `SECRET_KEY_BASE` and `RAILS_MAX_THREADS` are not offered either.
7. **No `<form>` element.** Without one, Enter in a field cannot submit the values into a query
   string even if the script failed to load. A request test asserts the page has no form.
8. **Validation in the browser:** port 1–65535, PUID/PGID whole numbers, the image tag's grammar, a
   host path with no `:` beyond a Windows drive letter, SMB server/share/user present and free of the
   characters that would break `//server/share` or the `o` option list, `APP_HOST` required with
   `SMTP_ADDRESS` (the boot refuses the pair without it). Invalid input disables Download and Copy.
9. **YAML scalars:** plain only when unambiguous (a letter or `/` first, no space, `#`, quote, `$` or
   flow indicator, not a YAML 1.1 boolean/null word); everything else double-quoted with JSON escapes
   (valid YAML), U+2028/U+2029 and C1 controls escaped too. Every `$` is written `$$` (compose
   interpolation); a comma in the SMB password is written `,,` (the `o` list).

10. **The phone gutter is the shell's 12px, not 16px.** The brief asked for 16px, but `shell.css`
    gives `main.container` 12px of side padding below 720px on every page; this page follows it
    rather than standing out. The system test asserts both panels stay inside that gutter.
11. **`.dockerignore` re-includes `docker-compose.yml`.** The image excluded every compose file, so
    reading it at render time would have been a 500 on every deployment while every test (run from a
    checkout) stayed green. Only the base file comes back.

## Verified by hand (not in CI)

`docker compose config` (Compose v5.5.0, this Mac) accepted five generated files (defaults, a
folder with `$`/`#`/quotes, an SMB share with a comma/`$`/`${HOME}`/backslash password and Tools
off, a guest share, mail with `on` as a HELO name) and read every typed value back exactly. Note
that `config` prints a literal `$` as `$$` (its output is itself a compose file), measured with a
control file; the comparison undoes that one escape. Not in CI because the runners have no Docker
CLI requirement and the Psych comparison carries the same claim.

## Tasks

1. `Tinkerex::ComposeTemplate` + unit test (TDD), `.dockerignore` re-include + guard.
2. `lib/compose_file.js`, `compose_controller.js`, importmap pin.
3. Route, `Public::ComposeController`, view, `pages/public.css` rules, header intro hook.
4. Request test (signed out on a self-host box and on the demo box, signed in, no form, links).
5. System test (drift, Tools off, share example, escaping matrix, validation, download, 375px,
   no request carries a value). Mutation-check each guard.
6. Links: the landing (footer and closing actions) and INSTALL.md's Quick start
   (`https://tinkerex.com/install/compose`, the host read from `config/deploy.ovh.yml` by the test).
7. Drive the page in the browser pane (desktop, 375px, light, dark); bare `bin/ci`; PR; arc; merge.
