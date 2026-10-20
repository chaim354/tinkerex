# Worker brief — Tinkerex simplification audit (read-only)

You are one reviewer in a coordinated, read-only audit of the Rails 8 app at
/Users/charlesschwartz/Desktop/repos/tinkerex. You own ONE subsystem (given in your task prompt).

## Hard constraints
- READ-ONLY. Do not edit, create, move or delete any file under the repository. Do not run tests,
  `bin/ci`, `bin/rails`, `bundle`, `git checkout`, `git stash`, or anything that writes under the
  repo (including `tmp/`). Allowed: `cat`, `sed -n`, `grep`, `rg`, `find`, `ls`, `wc`, `git log`,
  `git show`, `git blame`, `git ls-files`. The ONLY file you may write is your report file, whose
  path is given in your task prompt (it is outside the repository).
- Stay inside your ownership boundary. You may NOTE a cross-subsystem concern in a separate
  "Cross-subsystem notes" section, but do not expand your scope to solve it.
- Read `CLAUDE.md` §14 (the invariants) and any `docs/invariants/<area>.md` your row names BEFORE
  recommending anything: a "simplification" that undoes a recorded invariant is a rejection, not
  a finding. Many comments in this codebase explain why something is NOT simplified; take those
  seriously and argue against them only with evidence from the code.

## What to review
Review the assigned subsystem for AT MOST TWO materially useful simplifications in its data
structures, state representation, control flow, algorithms, or ownership/organizing model.

Inspect its implementation, public interfaces, major call sites, and existing tests.

Look for:
- scattered booleans or nullable fields that permit invalid combinations and should become a
  state machine or discriminated union;
- repeated assumptions about object shape that need a shared typed model;
- duplicated branching that a small map, registry, reducer, or command model would remove;
- unclear state or behavior ownership that a small module boundary would clarify;
- repeated scans, transformations, or lookups where a more appropriate collection or index would
  materially simplify behavior;
- lifecycle, concurrency, or async states whose representation permits stale or contradictory
  state.

Do NOT force an abstraction. Prefer boring local code when it is already clear.
Do NOT recommend changes solely for stylistic consistency, hypothetical extensibility, minor
line-count reduction, or moving existing branching behind a new type.

Return at most two opportunities. If nothing clearly meets the threshold, return `skip` — a skip
with a short account of what you inspected and why it clears the bar is a GOOD result.

## Report format (write this to your report file, then summarise in your final message)
```
# <ROW ID> — <subsystem name>
Reviewer verdict: recommend | skip
Files read: <list every file you actually opened, with approximate line coverage>

## Opportunity 1: <short title>
1. Verdict: recommend
2. Evidence: exact file:line references (several), quoting the relevant lines briefly
3. Current complexity or invalid states: what the representation permits/costs today, concretely
4. Proposed representation and why it is simpler: the target shape, in a few lines of
   illustrative code where helpful
5. Smallest credible implementation scope: affected files and interfaces, in order
6. Regression risks and migration concerns: data, API, UI, backend legs (share/s3/chunk_remote)
7. Existing and additional validation required: which existing tests pin the behaviour; what new
   test(s) would prove the change and the mutation that would show the new test carries weight
8. Confidence: high | medium | low (and why)

## Opportunity 2: ... (same schema) — omit if none

## Considered and rejected
Bullet list of candidate simplifications you looked at and why they do NOT clear the bar
(including any that would violate a recorded invariant). This is required even for `skip`.

## Cross-subsystem notes
Anything you noticed outside your boundary (one line each, with file:line). May be empty.
```

Your final message to the coordinator: the verdict line, the opportunity titles with confidence,
and the path of your report. Keep it under 25 lines; the report file carries the detail.
