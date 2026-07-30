---
description: Verify with bin/ci, then commit, push, and open a PR for the current branch
---

Close out the work on this branch: verify, commit, push, open a PR. Do not ask for
permission at each step — CLAUDE.md §15 ("Finishing work") is standing authorization for
everything below. **Merging is the one thing that still needs an explicit go-ahead.**

## 1. Check you're clear to do this

- `git branch --show-current` — if it is `main`, **stop**. Never commit or push to `main`.
  Report that the work needs a branch first.
- `git status --short` — if nothing is modified, say so and stop.
- Look at the actual diff (`git --no-pager diff` plus `git --no-pager diff --staged`).
  If it contains anything you did not intend — a stray scratch file, a debug probe, a
  committed secret, an unrelated edit — deal with that before going further.

## 2. Verify

Run the full gate, not a subset:

```bash
bin/ci
```

- All gates must pass: style, scan, test, test-share, test-s3, system.
- **The three test legs must report identical run/assertion counts.** A divergence means a
  test depends on the ambient `LIBRARY_BACKEND` — that is a real bug, not noise.
- **If anything is red, STOP.** Do not open a PR to "get it looked at". Report what failed,
  with the actual output.
- If a gate cannot run here (a missing runner, an unavailable service), say so explicitly
  and name it in the PR body as not verified. Never imply coverage you did not get.

## 3. Commit

One commit unless the work genuinely splits into independent changes.

Follow this repo's message style — read `git log --oneline -10` first. The subject states
the *effect*, not the mechanics ("the Add-task form emitted a param name require() rejects",
not "fix form"). In the body cover:

- the symptom a user would have seen, and since when
- the root cause, concretely (name the mechanism)
- why existing tests did not catch it, if they didn't
- what you verified, with numbers

End with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

## 4. Push and open the PR

```bash
git push -u origin "$(git branch --show-current)"
```

Then `gh pr create --base main`. The body should let a reviewer skip the diff and still
know what changed:

- **What was broken / what this adds**, in a sentence
- **Root cause**, with the specific mechanism
- **The fix**, and any decision a future editor might undo (if it's an invariant, it also
  belongs in CLAUDE.md §14)
- **Why tests missed it**, if applicable
- **Verification table** — every gate and its result
- **Scope**: what you deliberately did *not* touch

End with:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## 5. Watch CI, then report

Do not poll in a loop. Arm a monitor that emits one event per check and exits when the run
completes, then report the results as a table.

**First check whether CI will run at all.** `ci.yml` has a `paths:` allowlist (`app/`,
`config/`, `db/`, `lib/`, `test/`, `bin/`, `ci/`, `Gemfile*`, `.ruby-version`, and itself),
so a **docs-only or `client/**`-only PR triggers nothing** — `gh pr checks` reports "no
checks reported" and the PR is still `MERGEABLE`/`CLEAN`. That is correct behaviour, not a
broken pipeline. In that case say so plainly and let the local `bin/ci` run stand as the
verification; do not imply CI validated the change.

A monitor loop must therefore distinguish **"no checks exist"** from **"checks not reported
yet"**. Treating an empty result as "keep waiting" spins until timeout — verify with one
`gh pr checks` call before arming anything, and give the loop a bounded number of empty
polls before it concludes none are coming.

If CI fails on something `bin/ci` passed, that difference is itself the finding — say so
rather than just retrying.

Finish by giving the user the PR URL, the check results, and a one-line statement of what
still needs their decision (normally: whether to merge).

## Never

- Merge, `--admin` merge, or push to `main`
- Open a PR on red or partial work
- Claim a gate passed without having seen it pass
