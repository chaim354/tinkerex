# STATUS.md Migration Implementation Plan (PR 2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all 112 `docs/STATUS.md` sections and the three duplicate open-work lists into Forgejo, rewrite every citation, and delete `docs/STATUS.md` and `docs/OPEN-WORK.md`.

**Architecture:** A split script cuts the file into per-section markdown; `bin/log arc --from-file` imports each as a **closed** `arc` issue, emitting a `heading → issue #` mapping; that mapping drives the citation rewrite; a guard then fetches every rewritten number and requires 200.

**Tech Stack:** Ruby 3.4.7 stdlib, `bin/log` (merged in PR 1), Forgejo 11.0.16 at `forgejo.home`.

**Spec:** `docs/superpowers/specs/2026-08-26-status-to-forgejo-design.md`

---

## Measured facts this plan is built on

Everything below was probed against the live instance or the real file on 2026-08-26. **Do not re-derive these by reasoning; if one looks wrong, re-probe it.**

| Fact | Value |
|---|---|
| `docs/STATUS.md` | **112 sections, 12,809 lines** |
| Largest single section | **1,070 lines** |
| Forgejo body limit | **≥200,000 chars accepted** — the largest section fits with room to spare |
| `closed: true` on issue create | **Works** — returns `state: closed` |
| Issue labels on the wire | **int64 IDs, never names** — `bin/log` resolves them |
| Duplicate label names | **Forgejo allows them** — `setup` asks what exists first |
| `docs/STATUS.md` citations in `app/ lib/ test/ config/ .claude/` | **20** |
| `§12` citations in code | **21** |
| `§14`/`§15` citations in code | **515 — these stay in git** |
| `CLAUDE.md` | **1,498 lines**, ceiling 1,500 |

### The prune was dropped, deliberately

The spec called for a rubric-strict prune expected to keep 35–50 of 110. **Measured, that estimate was wrong**: with the rubric tightened to exclude per-entry suite counts (which STATUS.md's own preamble calls unusable as a baseline), it keeps **67 of 112 entries and 10,657 of 12,809 lines — 83%**. The value is distributed, not concentrated in a droppable tail.

Also measured: rubric rule 1 — *"a CLAUDE.md invariant or code comment cites it"* — matches **zero** entries. CLAUDE.md cites `docs/STATUS.md` generically, never a specific arc.

**So all 112 migrate.** The unreadability was one 234k-token file, and the container change fixes it: 112 issues of ~114 lines each are read one at a time. Deleting 45 to save 17% of lines nobody loads anyway trades recorded lessons for nothing. Pruning stays available afterwards — closing or deleting an issue is cheap.

---

## File Structure

| File | Responsibility |
|---|---|
| **Modify** `bin/log` | `arc --from-file <path> [--closed]` — import a section as an issue |
| **Create** `bin/split-status` | Cuts `docs/STATUS.md` into per-section files. One-shot, deleted in Task 7 |
| **Modify** `test/log_cli_test.rb` | Guards for `--from-file` and `--closed` |
| **Modify** `CLAUDE.md` | §11 rewritten, §12 frozen to a pointer table, §15 close-out and deploy rules |
| **Modify** `.claude/commands/` | `finish-branch.md`, `deploy.md` |
| **Modify** `test/docs_hygiene_test.rb` | The citation guard, and a lowered `MAX_LINES` |
| **Delete** | `docs/STATUS.md`, `docs/OPEN-WORK.md`, `bin/split-status` |

---

## Task 1: `bin/log arc --from-file`

**Files:** modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  # HISTORICAL ARCS ARRIVE ALREADY FINISHED, so they must be created CLOSED. Probed against the
  # live instance: CreateIssueOption accepts `closed: true` and returns state "closed".
  test "arc --from-file imports a section, closed, with its first heading as the title" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## 2026-07-29: the audit-fix arc\n\nTwo security gates ran zero.\n")

      _out, err, code = run_log("arc", "--from-file", path, "--closed", env: {
        "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
        "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
      })

      assert_equal 0, code, "import failed: #{err}"
      post = stub.requests.find { |r| r.method == "POST" }

      assert_equal "2026-07-29: the audit-fix arc", post.json["title"],
                   "the leading '## ' must be stripped, or every title starts with markup"
      assert_includes post.json["body"], "Two security gates ran zero."
      assert_equal true, post.json["closed"], "a finished arc must not import as open work"
      assert_equal [ 1 ], post.json["labels"]
    end
  ensure
    stub&.shutdown
  end

  # WITHOUT --closed IT STAYS OPEN. The same verb serves a live arc (opened at PR time, closed at
  # merge) and a historical import, so the default must be the live case — an import that forgets
  # the flag leaves a visible open issue, while the reverse silently closes live work.
  test "arc --from-file without --closed does not send closed" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## live arc\n\nbody\n")
      run_log("arc", "--from-file", path, env: { "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url })

      post = stub.requests.find { |r| r.method == "POST" }
      refute post.json.key?("closed"), "an import default of closed would silently close live work"
    end
  ensure
    stub&.shutdown
  end

  # A FILE WITH NO HEADING IS REFUSED, not imported under a guessed title. 112 sections import
  # unattended; one silently titled "" is one nobody finds again.
  test "arc --from-file refuses a file with no leading heading" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.md")
      File.write(path, "no heading here\n")

      _out, err, code = run_log("arc", "--from-file", path, env: { "FORGEJO_TOKEN" => "t0ken" })

      assert_equal 2, code
      assert_includes err, "no leading heading"
    end
  end
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement, inside `module Log`**

Extend `arc` to accept either form:

```ruby
  def arc(argv)
    flag = argv.shift
    closed = false
    title, body = nil

    case flag
    when "--from-pr"
      number = argv.shift or raise UsageError, "arc needs --from-pr N"
      pr = pull_request(number)
      title = pr["title"]
      body = "#{pr['body']}\n\n---\nPR: #{pr['url']}\n"
    when "--from-file"
      path = argv.shift or raise UsageError, "arc needs --from-file PATH"
      title, body = section(path)
    else
      raise UsageError, "arc needs --from-pr N or --from-file PATH"
    end

    closed = true if argv.include?("--closed")
    issue = create_issue(title, body: body, labels: [ "arc" ], closed: closed)

    puts "##{issue['number']} #{issue['title']}"
    EXIT_OK
  end

  # THE FIRST HEADING IS THE TITLE, and its absence is a refusal rather than a guess. 112 sections
  # import unattended; one silently titled "" is one nobody ever finds again.
  def section(path)
    text = File.read(path, encoding: Encoding::UTF_8)
    heading = text[/\A\s*#+\s*(.+)$/, 1] or
      raise UsageError, "#{path}: no leading heading — cannot title the issue"

    [ heading.strip, text.sub(/\A\s*#+\s*.+$\n?/, "").strip ]
  end
```

And `create_issue` takes the flag:

```ruby
  def create_issue(title, body:, labels:, closed: false)
    payload = { title: title, body: body, labels: labels }
    payload[:closed] = true if closed
    resolved = payload.merge(labels: label_ids(labels))
    parse(api(:post, repo_path("/issues"), resolved), "/issues")
  rescue Unreachable => e
    raise Unreachable.new(e.message, payload: e.payload || payload, path: e.path || "/issues")
  end
```

- [ ] **Step 4: Verify** — expect **PASS, 37 tests**; `bin/rubocop` clean.
- [ ] **Step 5: Mutation-check three, reporting each** — strip the heading-required raise (RED); default `closed` to true (RED on the without-`--closed` test); stop stripping `## ` from the title (RED). Restore each.
- [ ] **Step 6: Commit** — `bin/log arc --from-file: import a finished section as a closed issue`.

---

## Task 2: the split script

**Files:** create `bin/split-status`

- [ ] **Step 1: Write it**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Cut docs/STATUS.md into one file per `## ` section, for import by `bin/log arc --from-file`.
#
# ONE-SHOT AND DELETED IN THE SAME PR. It exists so the import is reproducible and reviewable
# rather than a hand-run pipeline, not because the repo needs a permanent splitter.
#
#   bin/split-status <outdir>
require "fileutils"

out = ARGV[0] or abort "usage: bin/split-status <outdir>"
FileUtils.mkdir_p(out)

lines = File.readlines(File.expand_path("../docs/STATUS.md", __dir__))
starts = lines.each_index.select { |i| lines[i].start_with?("## ") }
abort "no '## ' sections found — has the file moved?" if starts.empty?

starts.each_with_index do |start, n|
  finish = starts[n + 1] || lines.size
  title = lines[start][3..].strip
  date = title[/\d{4}-\d{2}-\d{2}/] || "0000-00-00"
  slug = title.downcase.gsub(/[^a-z0-9]+/, "-")[0, 60].delete_prefix("-").delete_suffix("-")

  File.write(File.join(out, format("%03d-%s-%s.md", n, date, slug)), lines[start...finish].join)
end

puts "#{starts.size} sections written to #{out}"
```

- [ ] **Step 2: Run it and check the count**

```bash
chmod +x bin/split-status && bin/split-status /tmp/status-split
```

Expected: **`112 sections written`**. A different number means the file changed since this plan was measured — stop and re-measure rather than proceeding.

- [ ] **Step 3: Verify nothing was lost**

```bash
cat /tmp/status-split/*.md | wc -l   # compare against: wc -l docs/STATUS.md
```

The split total will be **slightly lower** than 12,809 — the preamble above the first `## ` is not in any section. Confirm the difference equals exactly that preamble's length, and **carry the preamble nowhere**: it describes the file being deleted.

- [ ] **Step 4: Commit.**

---

## Task 3: import, capturing the mapping

**Files:** none committed — this task produces `/tmp/status-map.tsv`

- [ ] **Step 1: Ensure the labels exist** — `bin/log setup`. Expect `11 labels present`.

- [ ] **Step 2: Import oldest-first, appending to the map**

Sections are numbered newest-first by the splitter, so import in **reverse** filename order to make issue numbers track time.

```bash
: > /tmp/status-map.tsv
for f in $(ls -r /tmp/status-split/*.md); do
  n=$(bin/log arc --from-file "$f" --closed | sed 's/^#\([0-9]*\).*/\1/') || { echo "FAILED at $f"; break; }
  printf '%s\t%s\n' "$(basename "$f")" "$n" >> /tmp/status-map.tsv
  echo "  $(basename "$f") -> #$n"
done
wc -l < /tmp/status-map.tsv
```

Expected: **112 lines**. If `bin/log` exits 3 partway, the remainder are spooled — run `bin/log status`, fix the cause, and re-import **only** the sections missing from the map. Do not re-run the whole loop; Forgejo does not deduplicate issues any more than it deduplicates labels.

- [ ] **Step 3: Verify the import**

```bash
bin/log search "2026-" | head -5
bin/log status              # must report nothing unfiled
```

Confirm the issue count via the API equals 112 plus whatever existed before.

---

## Task 4: the three open-work lists become issues

**By hand. This is the one step that is not scriptable.**

`docs/OPEN-WORK.md` (19), `CLAUDE.md` §12 (13, of which 4 are already CLOSED/DONE), and STATUS.md's "Still open" (7) are **three overlapping views of the same work, not 39 distinct items** — no cross-reference links them, so merging them is a judgement call.

- [ ] **Step 1: Read all three lists and write the merged set to a scratch file**, one section per item, each naming **every source it came from** so nothing is dropped as a duplicate that was actually distinct.

- [ ] **Step 2: File each as an open issue**

```bash
bin/log open "<title>" "<body naming its sources>"
```

The four §12 items already marked CLOSED/DONE/RESOLVED import as **closed** issues — they keep their slot in the pointer table (code cites `§12.7`), and their state records that they are finished.

- [ ] **Step 3: Record `§12.N → #issue` in `/tmp/status-map.tsv`** alongside the arc mappings. Task 5 reads both.

---

## Task 5: rewrite every citation

**Files:** 20 code files, `CLAUDE.md`, `.claude/commands/finish-branch.md`, `.claude/commands/deploy.md`

- [ ] **Step 1: The 20 code citations**

```bash
grep -rn "STATUS.md" app/ lib/ test/ config/ .claude/
```

Each becomes `tinkerex#N` using the mapping. Where a comment cites STATUS.md *generically* ("the full story is in docs/STATUS.md") and no single issue is the referent, point it at the **§11 base URL** instead — do not invent a number.

- [ ] **Step 2: CLAUDE.md §11** — replace the STATUS.md pointer with the Forgejo instance and `bin/log search`. **The base URL lives here and nowhere else**, so the host can move without touching 20 comments.

- [ ] **Step 3: CLAUDE.md §12** — collapse to a 13-line pointer table:

```
7.  RESOLVED — SQLite3::BusyException was a stalled fsync → tinkerex#N (closed)
```

Never renumber. All 21 code citations must keep resolving; the *state* now lives in Forgejo.

- [ ] **Step 4: CLAUDE.md §15** — the STATUS bullet becomes `bin/log arc --from-pr`, and **the deploy-record-to-`main` exception is deleted outright**, paragraph and all. Its whole justification was that a deploy record could not live in the work's own PR; as an issue that reasoning evaporates.

- [ ] **Step 5: `/finish-branch`** — step 5 becomes `bin/log arc --from-pr <n>` after `gh pr create`. **`/deploy`** — the "RECORD THE DEPLOY IN `docs/STATUS.md`" step becomes `bin/log deploy --image <sha>`. Both gain a `bin/log status` check at the **start**, so an unfiled record from a previous run surfaces before new work begins.

---

## Task 6: the guards

**Files:** modify `test/docs_hygiene_test.rb`

- [ ] **Step 1: Write the guard**

```ruby
  # DELETING docs/STATUS.md WALKS STRAIGHT INTO §14e's RECORDED TRAP — "a guard that scans a
  # directory dies silently when the directory leaves". Two architecture guards were assert_empty
  # over a glob of engines/tinkerex-sync/**, and the extraction made that glob [], which satisfies
  # assert_empty perfectly. So this asserts its scanned set is NON-EMPTY before trusting it.
  test "no source file cites the retired docs/STATUS.md" do
    files = Dir.glob("{app,lib,test,config,.claude}/**/*.{rb,yml,md}", base: Rails.root)
    refute_empty files, "the scan found no files at all — did the layout move?"

    offenders = files.select { |f| Rails.root.join(f).read.include?("docs/STATUS.md") }

    assert_empty offenders, <<~MSG
      These still cite a file that no longer exists: #{offenders.join(', ')}
      The record lives in Forgejo now — cite `tinkerex#N`, or CLAUDE.md §11 for a generic pointer.
    MSG
  end
```

- [ ] **Step 2: Mutation-check it** — add `# docs/STATUS.md` to any scanned file, confirm **RED**, remove, confirm green. Then point the glob at a directory that does not exist and confirm the `refute_empty` fires — the vacuity check must itself be checked.

- [ ] **Step 3: Verify every rewritten citation resolves.** `bin/verify-fix-log`'s lesson is that a doc row naming a commit is an unverifiable claim. Here it *is* verifiable:

```bash
grep -rhoE 'tinkerex#[0-9]+' app/ lib/ test/ config/ .claude/ CLAUDE.md | sort -u | \
  sed 's/.*#//' | while read n; do
    printf '#%s -> ' "$n"; bin/log show "$n" >/dev/null 2>&1 && echo ok || echo "DANGLING"
  done
```

Every line must read `ok`. **Then mutation-check this too**: point one citation at issue `999999`, re-run, confirm `DANGLING` appears.

---

## Task 7: delete, and ratchet

- [ ] **Step 1: Delete** `docs/STATUS.md`, `docs/OPEN-WORK.md`, and `bin/split-status`.

**In the same commit as Task 5's rewrite.** A merged tree with rewritten citations but STATUS.md still present is merely redundant; the reverse — STATUS.md deleted while 20 comments still point at it — is 20 dead references on `main`.

- [ ] **Step 2: Lower `MAX_LINES`** in `test/docs_hygiene_test.rb` to CLAUDE.md's new length, rounded up to the next 50. The ceiling is a ratchet; §12 collapsing from ~90 lines to 13 is what buys the room.

- [ ] **Step 3: Confirm the history is still reachable** and say so in the PR body:

```bash
git show HEAD~1:docs/STATUS.md | wc -l    # 12,809
```

Nothing is lost by the delete — only by a history rewrite, which nobody is doing.

---

## Task 8: close out

- [ ] **Step 1: `bin/ci`** — all gates green, three legs identical.
- [ ] **Step 2: `bin/log status`** — must report nothing unfiled.
- [ ] **Step 3: `/finish-branch`**, then `bin/log arc --from-pr <n>` — **the migration files its own arc through the mechanism it installed.** That is the smoke test that matters.

---

## Out of scope

- `-sync` and `-client`, which replicate the convention afterwards.
- Pull-mirroring the repos (declined: all three GitHub repos are private, so it would mean a GitHub PAT stored inside Forgejo, a second long-lived credential outside the `bin/secret` path).
- Retiring `AUDIT-*`, `FIX-LOG-*`, `HANDOFF-*`.
- Moving invariants. §14 and `docs/invariants/` stay in git — 515 code citations depend on resolving with no network call.
