# docs/

Everything here is current. The canonical record of finished work is not a file here at all: it is
the Kaneo project CLAUDE.md §11 names, read with `bin/log`.

## At the top, because other places link to them by path

| file | what it is |
|---|---|
| `INSTALL.md` | How a stranger runs the app with docker compose; the environment reference (kept complete by `test/install_docs_test.rb`). The landing page and Help link to its GitHub URL. |
| `addon-api-v1.md` | How to write an addon for the Tools gallery. `tinkerex-addons` cites it by this path. |

## `guides/`

| file | what it is |
|---|---|
| `DEPLOY.md` | The author's Kamal runbook for the author's hosts. Not for strangers. |
| `mcp.md` | Connecting an AI assistant over MCP, and the tools it gets. |
| `adding-a-preview-format.md` | How to add a preview renderer. |

## `reference/`

| file | what it is |
|---|---|
| `roads-not-taken.md` | Approaches considered and rejected, with the why. Read before reviving any of them. |
| `schema-map.html` | Generated map of every table and relationship (`bin/rails schema:map`). |

## `invariants/`

The area-scoped rules CLAUDE.md §14 points into. Not optional reading inside their areas.

## `superpowers/`

Where the brainstorming and planning skills write a feature's spec and plan while it is being built.

## Deleted on 2026-11-10

330 files went: every audit and fix log, every finished plan and spec under `superpowers/`, the
pre-split `plan-*.md` and `research-*.md` files, `adr/`, and the docs marked HISTORICAL. Code
comments and the files above still cite some of them by path. Each one is in git history as it was
on the last commit that held it:

```sh
git show 9c65d143:docs/<path>                      # read one
git ls-tree -r --name-only 9c65d143 -- docs/       # list what was there
```
