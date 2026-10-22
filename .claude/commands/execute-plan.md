---
description: THE DEFAULT way to execute an implementation plan with subagents in this repo — batched by file, parallel where independent, no spec-compliance stage, one capped quality review per task
---

**THIS IS THE DEFAULT, NOT AN ALTERNATIVE.** Follow it whenever you dispatch subagents to execute a
plan in this repo, whether or not anyone invoked `/execute-plan`. Where it disagrees with a generic
subagent-driven-development skill, **this wins** — CLAUDE.md §15 says so, and the superpowers skills
themselves rank a repo's own instructions above their defaults. You do not need permission to work
this way; you need a reason not to.

**The measurement this exists because of** (project-discovery arc, 2026-08-26, ~3.4 h of subagent
time): reviews cost **~1.8 h against ~1.6 h of implementation**, so review was the majority of the
spend. Two specific wastes, both fixed below — an 11-task plan that split one file across three
tasks, and six spec-compliance dispatches that found **zero** divergences between them.

**What is NOT cut:** quality reviews stay full-depth, and plans stay prescriptive. On that same arc
the quality reviews caught a destination bug found before any code existed, three tests that passed
while the swept code was completely broken, an operator env knob that would have shipped inert with
16 green tests, and a concurrency comment claiming protection it did not provide. Those are this
repo's recorded failure shapes (§15). Cutting them is not the optimization.

## 1. Batch the plan before dispatching anything

The plan is probably written as TDD steps. **Do not dispatch it that way.**

- **One task = one file, or one coherent unit, owned end-to-end by a single implementer** —
  including every mutation check that unit needs. A service and its test file are ONE task, not
  three (happy path / edge rules / caps).
- Expect to roughly **halve** the task count the plan's step-wise split implies.
- Re-batching is yours to do; you do not need to rewrite the plan file to do it.

## 2. Dispatch independent tasks in parallel

The "never dispatch implementers in parallel" rule is about **conflicting edits**, not about
independence. Before dispatching:

- List the paths each task touches.
- Tasks touching **disjoint** paths go out **in one message** so they run concurrently.
- Serialize only genuine dependencies (task B needs a constant task A introduces) and same-file work.

## 3. Per task: implementer → your own mechanical check → one capped quality review

**There is no spec-compliance reviewer.** It only ever confirmed the implementer pasted the plan's
code correctly, which is cheaper to check yourself:

```bash
git diff --stat <base>..<head>          # is the changed-file list exactly what the task named?
git diff <base>..<head> -- app/ | wc -l # for a tests-only task this must be 0
```

For a task whose plan gave verbatim code, extract the plan's fenced blocks and `diff` them against
the committed files. That is the whole of what the dropped stage was doing.

**Then dispatch ONE quality reviewer, with its scope capped.** An uncapped review re-read half the
codebase for sixteen minutes to check three claims. In the prompt:

- Name the specific claims to verify, numbered.
- Say **"do not re-derive the whole file or audit code outside the diff."**
- Tell it to run the named mutations itself and report actual output.
- Say plainly that a clean review is a fine outcome and it must not manufacture findings.

## 4. Rules that cost real time when they were missing

- **When a change invalidates documented behaviour, the SAME task sweeps every file describing it.**
  One fix on that arc falsified five comments across four files, discovered one at a time over five
  round trips. Instruct the implementer: "grep every file that documents X's behaviour and fix all
  of them now."
- **Restore mutation-checked files with `git checkout -- <file>`, never `cp`.** Then
  `git status --porcelain` before the next run.
- **AN INTERRUPTED REVIEWER LEAVES ITS MUTATION IN YOUR TREE.** A capped review is told to mutate
  production code and restore it; if the dispatch is cancelled mid-run, the restore never happens
  and the working tree silently carries a `return false` someone asked for two minutes ago. Observed
  2026-08-26 — caught only because an unrelated `git status` listed a file the task had no business
  touching. **After any cancelled or errored subagent, run `git diff --stat origin/main -- app/ lib/
  config/ db/` before you commit anything.** A green `bin/ci` from *before* the dispatch does not
  clear the tree you are about to commit from.
- **A guard is not done until it has been made to fail.** Every mutation gets its actual output
  reported, not a claim that it went red. This is §15's rule and it is the one that keeps paying.
- **Trust implementer reports by default.** Across that whole arc, every report that was challenged
  turned out to be accurate — including one the orchestrator wrongly announced as false. Verify by
  re-running the gate, not by re-litigating the narrative.

## 5. Close out

Run bare `bin/ci` yourself. It compares the three backend legs' RUN counts itself — `test` (share),
`test-s3`, `test-chunk-remote` must be identical (§15) — and goes red when they differ; assertion
counts differ between legs by design and are not compared. From a worktree, export
`TINKEREX_SYNC_DIR` to the real sibling checkout or the chunk_remote leg cannot find the sync repo.

Then `/finish-branch`. Record the arc with `bin/log` — that is the single write door onto the
canonical record (CLAUDE.md §11), and it is part of the work, not a follow-up.
