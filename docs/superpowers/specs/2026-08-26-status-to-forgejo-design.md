# `docs/STATUS.md` retires to a self-hosted Forgejo

**Date:** 2026-08-26
**Branch:** `claude/status-to-forgejo`
**Scope:** this repo (`chaim354/tinkerex`) first; `-sync` and `-client` replicate the convention afterwards.

---

## 1. The problem, measured

`docs/STATUS.md` on `main` at 2026-08-26:

| | |
|---|---|
| Size | 12,680 lines · 916 KB · **~234,000 tokens** to read in full |
| Entries | 110 arcs · median 74 lines · mean 114 · **max 1,071** |
| Write traffic | **191 of 1,091 commits** in 60 days touch it (~18%) |
| Merge churn | 18 merge commits had to touch it |
| Coupling | 20 references in `app/ lib/ test/ config/ .claude/`, plus ~10 more in `docs/` |

Three failures, all confirmed by the user:

1. **Nobody can read it.** At ~234k tokens it does not fit a context window. The "canonical record" is grep-only in practice, and CLAUDE.md's ~20 citations of it ("the full story is in `docs/STATUS.md`") are dead links.
2. **Writing it taxes every PR.** §15 makes an entry mandatory in the same branch as the work. On a small fix the entry costs more than the fix.
3. **Parallel branches collide on it.** One append-at-top file, several `claude/*` branches in flight at once, all editing the same first 100 lines.

Explicitly **not** a problem: the arc is still the right unit of record. This is a container problem, not a content problem.

### 1.1 The mutable half is what rotted

"What to do next" already lives in three places:

| Where | Items |
|---|---|
| `docs/OPEN-WORK.md` | 19 |
| `CLAUDE.md` §12 | 13 — **4 already CLOSED/DONE**, kept forever because code cites `§12.7` by number |
| `STATUS.md` "Still open" | 7 |
| GitHub Issues, all three repos | **0, ever** (issues enabled) |

§12 keeping a CLOSED item in its slot permanently *because a code comment cites its number* is the
proof that a file is the wrong container for mutable state: it can never garbage-collect.

---

## 2. Decision

**A self-hosted Forgejo instance becomes the canonical record for both halves — finished arcs and
open work. Nothing is mirrored back into git.**

The instance already exists: **`forgejo.home` → 192.168.1.7, Forgejo 11.0.16+gitea-1.22.0**, currently
empty (0 repos visible anonymously). Measured latency from this box: DNS 1.6 ms, connect 4.2 ms,
total 7.8 ms.

### 2.1 Why Forgejo and not the alternatives

| | Verdict |
|---|---|
| **Forgejo** | **Chosen.** MIT — the only candidate matching §9 outright. Single Go binary + SQLite. Mature MCP servers (one exposes 103 tools over stdio and HTTP). Markdown issue bodies and comment threads host arc prose natively. Backs up as one SQLite file + attachments, folding into the existing `ops/backup-db.sh` shape (§14i) |
| Plane | **Rejected.** Its MCP server is an **Enterprise add-on only**, which defeats an agent-first workflow. Needs 8 GB RAM minimum in practice, 16 GB recommended; containers OOM at 4 GB. AGPL-3.0 |
| Huly | Rejected. MongoDB + Elasticsearch + MinIO on an already-tight VM; least mature agent story |
| Vikunja / OpenProject | Rejected. AGPL / GPL, and task-manager rather than issue-tracker shape — weak on long-form prose |

### 2.2 Costs accepted knowingly

These were raised twice and accepted by the user. They are recorded so nobody re-litigates them
as if they were oversights.

- **History requires the box.** With no git copy, `cat`-ing the record offline, in a fresh clone,
  in a cloud session, or from a container is no longer possible. Mitigations in scope: Forgejo's
  SQLite joins `bin/backup-db` / `bin/backup-status`; `bin/log` fails loudly, never silently.
- **`forgejo.home` is a LAN address.** Off-LAN sessions cannot reach it. The self-hosted CI
  runners are on this LAN, so CI is unaffected. A Tailscale MagicDNS name is a setup item.
- **~20 code comments will cite an issue number rather than a file path**, so reading them
  requires the box up.

A generated read-only git mirror was offered as a mitigation and **declined**. Do not add one back
without revisiting this section.

---

## 3. Scope — what moves, what stays

The citation counts draw the line:

| | Code citations | Verdict |
|---|---|---|
| §14/§15 — invariants, working agreements | **515** | **Stays in git** |
| §12 — what's open | **21** | **Moves** |
| `docs/STATUS.md` | **20** | **Moves** |

### 3.1 Moves to Forgejo

| Source | Count | Becomes |
|---|---|---|
| `STATUS.md` arc entries | 110, fewer after prune | Closed issue, label `arc` |
| `STATUS.md` "Still open" | 7 | Open issue, `open-work` + `deliberate` |
| `docs/OPEN-WORK.md` | 19 | Open issue, `open-work` |
| `CLAUDE.md` §12 | 9 live + 4 closed | Open / closed issue, `open-work` |
| Deploy records | ongoing | Issue, label `deploy` |

### 3.2 Stays in git

Read while working, cheap to load, not mutable state:

- `CLAUDE.md` §1–§11 and §13–§15 — architecture and invariants, loaded free every session
- `docs/invariants/*.md` — area rules
- `docs/superpowers/specs/` — inputs to implementation
- `docs/sync-protocol.md`, `DEPLOY.md`, `roads-not-taken.md`, `adr/`

**Invariants never move.** They are rules, not records, and 515 code citations depend on them
resolving without a network call.

---

## 4. The Forgejo model

**Instance.** One Forgejo on Unraid (Docker, SQLite). Three repos — `tinkerex`, `tinkerex-sync`,
`tinkerex-client` — **pull-mirrored from GitHub** so commit and file links in issue bodies resolve
and the instance doubles as a warm off-GitHub standby. GitHub remains the write remote.

**Objects:**

| Concept | Forgejo object | Closes when |
|---|---|---|
| Arc — finished work | Issue, label `arc` | The PR merges |
| Open item | Issue, label `open-work` | It's done |
| Deploy | Issue, label `deploy` | Verified on the box |
| Correction to a past arc | **Comment on that arc's issue** | — |

The last row is the sharpest gain. STATUS.md's recurring failure was stale claims buried mid-file —
CLAUDE.md documents several in its own voice ("this bullet went on asserting a single even bound for
months"; "the rule was right; its evidence was invented"). A dated comment appends visibly instead of
requiring someone to find and rewrite a paragraph at line 4,700.

**Labels:** type (`arc` / `open-work` / `deploy`) × area (`filelayer`, `library-scan`, `addons`,
`previews`, `maker-web`, `ci`) × modifier (`blocked`, `deliberate`).

### 4.1 The arc issue body *is* the PR body

`/finish-branch` already specifies that document — symptom, root cause, why tests missed it,
verification table, scope. The arc issue is created **from** the merged PR body rather than
hand-written a second time.

**This is why complaint #2 goes down, not up.** Today you write a PR body *and* a STATUS entry.
After this you write one document and file it.

---

## 5. `bin/log` — one write door

**`bin/log` is the only write surface. MCP is optional read/browse convenience and never required.**

Two write paths would be one verb with two answers — the shape §14a forbids, and the shape §14d
spent five copies of the `port_writable?` branch learning to avoid. A CLI also works everywhere MCP
does not: CI, cloud sessions, subagents, worktrees.

```
bin/log arc --from-pr 261        # arc issue from the merged PR body
bin/log open "<title>"           # file an open item
bin/log deploy --image e079d433  # record a deploy
bin/log note 128 "<correction>"  # append a comment to a past arc
bin/log show 128 | search <q>    # read
bin/log status                   # report anything unfiled
```

### 5.1 Credentials

The token resolves through **`bin/secret`** (`op://tinkerex/Forgejo/token`), never `export`.
Per the recorded leaks in this repo's own history, `bin/log` must not presence-test a secret with a
shell default, must get redirection order right, and must handle the failure branch of the capture.

Required scopes: `write:issue`, `read:repository`. **The user creates this token**; it is never
handled in a session.

### 5.2 When Forgejo is unreachable

**Fail loudly; let the PR proceed.** Chosen over blocking the close-out, and over a local spool
with automatic replay.

- `bin/log` errors visibly and writes the entry to `tmp/log-pending/<branch>.md`
- It prints that path
- **`bin/log status` reports anything outstanding**, and `/finish-branch` and `/deploy` check it at
  *start*
- **No automatic replay.** The spool exists so the text is not lost, not as a second store that
  silently drains

---

## 6. The workflow rewrite

### 6.1 CLAUDE.md — four edits, and the file gets shorter

| § | Change |
|---|---|
| §11 Status | Points at Forgejo and `bin/log search`. **The base URL lives here and nowhere else**, so the host can move without touching 20 code comments |
| §12 What's open | Freezes to a **13-line pointer table** (`§12.7 → #43 closed`). ~90 lines → 13. Never renumber; all 21 code citations keep resolving; it stops growing |
| §15 Finishing work | The STATUS bullet becomes a `bin/log arc` step, and **the deploy-record-to-`main` exception is deleted outright** |
| §15 Keeping docs honest | "STATUS.md is where an arc gets narrated" → "an arc is narrated in Forgejo." The split survives verbatim: **rule → §14, story → tracker** |

`test/docs_hygiene_test.rb` guards CLAUDE.md's line ceiling as a ratchet. This change shrinks the
file, so the ceiling drops with it — per the file's own rule.

### 6.2 Commands

- **`/finish-branch`** — step 5 becomes `bin/log arc --from-pr <n>`, creating the arc issue *open*
  from the body just written. It closes at merge, which already needs an explicit go-ahead.
- **`/deploy`** — line 144's "RECORD THE DEPLOY IN `docs/STATUS.md` as the LAST STEP" becomes
  `bin/log deploy --image <sha>`. No commit, no push to `main`.

### 6.3 Code citations

The 20 references become `# tinkerex#128`. Bare issue numbers; base URL resolved from §11.

---

## 7. Migration

**Pruning is recoverable.** Deleting `docs/STATUS.md` in a commit leaves
`git show <sha>:docs/STATUS.md` working forever. Nothing is lost unless someone rewrites history.

### Step 1 — mechanical split

A script cuts each `## <date>: <title>` section into its own file in a scratch dir. 110 files,
lossless, produces the work list.

### Step 2 — rubric-strict prune

An entry is kept in full if **any** of these holds:

1. A `CLAUDE.md` §14 invariant or a code comment cites it (the 20 code refs are non-negotiable)
2. It carries a **measured number** recorded nowhere else — STATUS.md's stated purpose
3. It records a **road not taken**, so nobody re-tries it
4. It describes code that still exists

Failing all four → compress to date + title + one line, or drop. Expected survival: **~35–50 of
110**. The 2026-08-20→25 band should shed heavily — much of it narrates the embedded chunk engine,
the eight dropped tables, and `engines/`, all of which now live in sibling repos.

### Step 3 — import, capturing a mapping

Oldest-first, so issue numbers track time. The script emits `heading → issue #`. That mapping file
drives Step 4 and is the artifact that makes the result verifiable.

**The three open-work lists are deduplicated during this step, by hand.** `docs/OPEN-WORK.md` (19),
§12 (9 live), and "Still open" (7) are three overlapping views of the same work, not 35 distinct
items — no cross-reference links them, so the merge is a judgement call, not a scriptable one. Each
surviving item becomes exactly one `open-work` issue. An item that appears in more than one source
gets **one** issue whose body names every source it came from, so nothing is silently dropped as a
duplicate that was actually distinct.

### Step 4 — rewrite citations

The 20 code references, plus CLAUDE.md §11/§12/§15 and the two commands, from the mapping.

### Step 5 — verify

`bin/verify-fix-log`'s lesson is that a doc row naming a commit is an unverifiable claim. Here it
*is* verifiable, cheaply, so it gets verified:

- Every rewritten citation is fetched from the API and must return **200** — no dangling numbers
- The guard **asserts it scanned a non-empty set** before trusting what it reports. Deleting
  `docs/STATUS.md` walks straight into §14e's recorded trap: *"a guard that scans a directory dies
  silently when the directory leaves"*
- **Mutation-check:** point one citation at a nonexistent issue, confirm red, restore

### Step 6 — delete `docs/STATUS.md` and `docs/OPEN-WORK.md`

After Step 5's verification passes, in the same PR as the citation rewrite. The deletion and the
rewrite must land together: a merged tree with rewritten citations but STATUS.md still present is
merely redundant, whereas the reverse — STATUS.md deleted while 20 comments still point at it — is
20 dead references on `main`.

### Staging

**Two PRs, in this order.** They are independent and the first is useful on its own:

1. **`bin/log` + Forgejo setup** — the CLI, credentials, labels, mirrored repos, `bin/log status`,
   and its tests. Nothing is deleted; STATUS.md still works. Merging this proves the write path
   before anything depends on it.
2. **The migration** — Steps 1–6 plus the CLAUDE.md and command rewrites, as one atomic change.

Splitting further would leave `main` in a state where the record is half-moved, which is the
condition that produced three duplicate open-work lists in the first place.

---

## 8. Out of scope

- `-sync` and `-client` migrate afterwards, using the same convention and the same `bin/log`.
- A read-only git mirror of the tracker (offered, declined — §2.2).
- Moving invariants (`CLAUDE.md` §14, `docs/invariants/`) anywhere. They stay.
- Retiring the other point-in-time docs (`AUDIT-*`, `FIX-LOG-*`, `HANDOFF-*`).

---

## 9. Setup items owned by the user

1. **Create a Forgejo access token** with `write:issue` + `read:repository`, stored as
   `op://tinkerex/Forgejo/token`.
2. **Tailscale MagicDNS name** for `forgejo.home`, if off-LAN access matters.
3. **Create or mirror the three repos** in Forgejo (or confirm they exist and are private —
   anonymous search returns 0).

---

## 10. Success criteria

- `docs/STATUS.md` and `docs/OPEN-WORK.md` are gone from the tree.
- `CLAUDE.md` is shorter, and `test/docs_hygiene_test.rb`'s ceiling has been ratcheted down.
- Every §12 citation in code still resolves; every rewritten `#N` citation returns 200.
- `bin/ci` is green, all three backend legs reporting identical counts.
- `bin/log arc --from-pr` files this arc's own PR as the first `arc` issue — the migration
  demonstrates the mechanism on itself.
