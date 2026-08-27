# Phase 5 — Refinement: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Read first:** [`00-overview.md`](2026-08-27-git-tracked-projects-00-overview.md) and the design's
> §9.5. **Phases 1–4 must be merged and running against real data for at least a week** — every task
> here needs measurements that do not exist until then.

**Goal:** replace the three deliberately-unpicked numbers with measured ones, and stop two caches
growing without bound.

**Architecture:** no new subsystems. Three bounded changes to things phases 3 and 4 shipped with
conservative defaults.

**Tech stack:** Rails 8, Solid Queue recurring jobs.

---

## Why these were deferred rather than guessed

Each of the three needs a number, and **a number picked without measuring is a number nobody can
argue with later.** Phase 3 and 4 shipped defaults chosen to fail in the safe direction:

| knob | shipped default | why it is safe to sit on |
|---|---|---|
| size threshold | none — role alone decides | text stays tracked, binaries do not. Conservative |
| repack policy | none — packs accumulate | one pack per window; §4.1 measured 20 commits → 38 KB |
| preview retention | none — rows accumulate | rows are small; the attachments are the cost |

None is urgent. All three become wrong slowly, which is exactly why they need a scheduled look
rather than an alarm.

---

### Task 1: Measure, then set, the size threshold

§5 routes "anything over a size threshold" to a pointer regardless of role. Phase 3 shipped without
one, so a 400 MB `.md` is currently committed as content.

**Files:**
- Create: `lib/tasks/git_tracking.rake`
- Modify: `app/services/maker/git/tracking.rb`
- Modify: `test/services/maker/git/tracking_test.rb`

- [ ] **Step 1: Write the measurement task**

```ruby
# lib/tasks/git_tracking.rake
namespace :git_tracking do
  # What WOULD be committed as content today, by size. Read-only; run it before choosing a
  # threshold rather than picking a round number.
  desc "Report the size distribution of content-tracked files per user"
  task size_distribution: :environment do
    User.find_each do |user|
      sizes = user.nodes.present.where(kind: "file")
                  .select { |n| Maker::Git::Tracking.mode_for(n.name) == :content }
                  .map(&:size).compact.sort
      next if sizes.empty?

      pct = ->(p) { sizes[(sizes.size * p / 100.0).floor.clamp(0, sizes.size - 1)] }
      puts format("user=%d n=%d p50=%s p95=%s p99=%s max=%s",
                  user.id, sizes.size,
                  *[ pct.(50), pct.(95), pct.(99), sizes.last ].map { |b| ActiveSupport::NumberHelper.number_to_human_size(b) })
    end
  end
end
```

- [ ] **Step 2: Run it against the real library**

Run: `bin/rails git_tracking:size_distribution` on the **share** deployment — that is where the real
data is; chunk and s3 hold test users only.

Record the output in the arc. **Choose the threshold from p99**, not from a round number: the goal is
to catch the pathological file without demoting ordinary source.

- [ ] **Step 3: Write the failing test**

```ruby
# test/services/maker/git/tracking_test.rb — append
test "a text file over the threshold becomes a pointer" do
  node = users(:one).nodes.create!(node_id: "n1", name: "huge.md", kind: "file",
                                   size: Maker::Git::Tracking::MAX_CONTENT_BYTES + 1,
                                   content_hash: "sha256:#{'a' * 64}")

  assert_equal :pointer, Maker::Git::Tracking.mode_for(node.name, size: node.size)
end

test "size is optional and omitting it keeps the role-only answer" do
  # Every phase-3 caller passes a size, but the predicate is also used where none is known (a
  # filename from a form). Defaulting to the role keeps those callers correct rather than
  # silently routing everything to :content.
  assert_equal :content, Maker::Git::Tracking.mode_for("notes.md")
end
```

- [ ] **Step 4: Implement**

```ruby
# app/services/maker/git/tracking.rb — add the constant and the optional kwarg

      # THE THRESHOLD IS MEASURED, NOT CHOSEN. Set from the p99 of content-tracked file sizes on
      # the real share library — see `rake git_tracking:size_distribution` and the arc that set it.
      # Round numbers here are how a limit ends up either useless or surprising.
      #
      # IT OVERRIDES ROLE, not the other way round: a 400 MB Markdown file is still a 400 MB blob,
      # and git stores each version of it whole.
      MAX_CONTENT_BYTES = <measured p99, rounded up to a readable figure>

      def mode_for(name, size: nil)
        return :pointer if size && size > MAX_CONTENT_BYTES
        return :content if Maker::FileAttachment.text_basename?(name)

        CONTENT_ROLES.include?(Maker::FileAttachment.role_for(name)) ? :content : :pointer
      end
```

Update `Maker::Git::ProjectCommit#paths_for` to pass `size: node.size`.

- [ ] **Step 5: Run, mutation-check, commit**

Run: `bin/rails test test/services/maker/git/tracking_test.rb` — PASS.
Mutate: drop the `size &&` guard so a nil size raises; confirm the second test goes RED. Restore.

```bash
git add app/services/maker/git/tracking.rb app/services/maker/git/project_commit.rb lib/tasks/git_tracking.rake test/
git commit -m "Size threshold for content tracking, set from the measured p99"
```

---

### Task 2: Full repack when packs accumulate

Phase 3 writes **one pack per commit window** and never collapses them. §4.1 measured that as
correct for the window (20 commits → 38 KB pack + 5.5 KB idx, existing pack untouched) — but a year
of daily windows is ~365 packs, and hydration fetches all of them.

**Files:**
- Modify: `app/services/maker/git/repo.rb`
- Modify: `config/recurring.yml`
- Modify: `test/services/maker/git/repo_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/git/repo_test.rb — append
test "repack_all! collapses many packs into one" do
  @repo.hydrate!
  5.times do |i|
    @repo.commit!(paths: { "f#{i}.txt" => "#{i}\n" }, message: "c#{i}")
    @repo.consolidate!
  end
  assert_operator @repo.pack_names.size, :>, 1, "setup should produce several packs"

  @repo.repack_all!

  assert_equal 1, @repo.pack_names.size
  assert_equal 5, @repo.log(limit: 10).size, "repacking must not lose history"
end

test "repack_all! is a no-op below the pack limit" do
  @repo.hydrate!
  @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")
  @repo.consolidate!
  before = @repo.pack_names

  @repo.repack_all!

  assert_equal before, @repo.pack_names
end
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — `NoMethodError: undefined method 'repack_all!'`

- [ ] **Step 3: Implement**

```ruby
# app/services/maker/git/repo.rb — add

      # BORROWED FROM GIT'S OWN gc.autoPackLimit DEFAULT rather than invented. Git has spent twenty
      # years deciding when a repository has too many packs; there is no reason to have a different
      # opinion, and a number with a source is one a later reader can check.
      MAX_PACKS = 50

      def pack_names = Dir.glob("objects/pack/*.pack", base: git_dir).map { |p| File.basename(p, ".pack") }

      # Collapse every pack into one. EXPENSIVE and rare: it reads every object and writes them
      # all back, so on s3 it is a full download and re-upload of the repository. That is why it is
      # gated on MAX_PACKS and runs weekly rather than per window.
      #
      # THE OLD PACKS ARE DELETED ONLY AFTER THE NEW ONE IS WRITTEN AND VERIFIED. The reverse order
      # is the copy-delete-tombstone landmine §14a records: a failure between the two leaves the
      # repository with no objects at all, and no error anywhere saying so.
      def repack_all!
        return if pack_names.size <= MAX_PACKS

        objects = all_objects
        result = PackWriter.write(File.join(git_dir, "objects/pack"), objects)
        (pack_names - [ result[:name] ]).each do |name|
          %w[pack idx].each { |ext| File.unlink(File.join(git_dir, "objects/pack/#{name}.#{ext}")) rescue nil }
        end
        persist_repack!(result[:name])
        result[:name]
      end
```

Implement `all_objects` by walking every pack's idx and reading each object through rugged.
`persist_repack!` writes the new pack and **deletes the superseded ones from the library** via
`FileLayer#delete_repo_data` — otherwise the library keeps every pack forever and the repack
achieves nothing where it matters.

- [ ] **Step 4: Add the schedule**

```yaml
  # Collapse accumulated packs. WEEKLY and off-peak: a repack reads and rewrites every object, so
  # on s3 it is a full download and re-upload of each repository. The threshold, not the cadence,
  # is what keeps it rare — most weeks this does nothing.
  git_repack:
    command: "Maker::Git::RepackJob.repack_all!"
    schedule: every sunday at 4am
```

- [ ] **Step 5: Mutation-check the ordering**

Move the `File.unlink` loop **above** `PackWriter.write`. Add a test that raises inside the writer
and asserts the repo still has its objects. Confirm it goes RED with the wrong ordering. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/git/repo.rb app/jobs/maker/git/repack_job.rb config/recurring.yml test/
git commit -m "Repack when packs exceed git's own autoPackLimit, new pack before old deletes"
```

---

### Task 3: Retire unviewed historical thumbnails

**Files:**
- Create: `app/jobs/maker/version_preview_reaper_job.rb`
- Modify: `config/recurring.yml`
- Create: `test/jobs/maker/version_preview_reaper_job_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/maker/version_preview_reaper_job_test.rb
require "test_helper"

class Maker::VersionPreviewReaperJobTest < ActiveJob::TestCase
  test "it reaps rows nobody has viewed inside the window" do
    # travel_to separates the two events by orders of magnitude. A timestamp compared at second
    # resolution is a guard that usually cannot fail (§15) — the row would otherwise be written in
    # the same second as the sweep that is meant to spare it.
    old = travel_to(90.days.ago) { create_row(token: "a") }
    fresh = create_row(token: "b")

    Maker::VersionPreviewReaperJob.perform_now

    assert_not Maker::VersionPreview.exists?(old.id)
    assert Maker::VersionPreview.exists?(fresh.id)
  end

  test "viewing a row protects it" do
    row = travel_to(90.days.ago) { create_row(token: "a") }
    row.touch_viewed!

    Maker::VersionPreviewReaperJob.perform_now

    assert Maker::VersionPreview.exists?(row.id), "last_viewed_at, not created_at, is the key"
  end

  private

  def create_row(token:)
    Maker::VersionPreview.create!(user: users(:one), node_id: "n1", content_token: token,
                                  kind: "b.stl", state: "ready")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — `NameError: uninitialized constant Maker::VersionPreviewReaperJob`

- [ ] **Step 3: Implement**

```ruby
# app/jobs/maker/version_preview_reaper_job.rb
module Maker
  # Historical thumbnails nobody has looked at recently.
  #
  # SAFE TO REAP UNCONDITIONALLY, unlike almost everything else in this codebase that gets swept:
  # these are DERIVED and regenerable — reopening History re-enqueues the render. Compare
  # Maker::AttachmentReaper, which waits out a grace window because destroying an attachment is
  # irreversible. Nothing here is.
  #
  # KEYED ON last_viewed_at, NOT created_at. A version nobody opens should age out even if it was
  # rendered recently; one people keep opening should stay. created_at would reap exactly the rows
  # that are being used.
  class VersionPreviewReaperJob < ApplicationJob
    queue_as :background

    RETENTION_DAYS = 60

    def perform
      Maker::VersionPreview.reapable(RETENTION_DAYS.days.ago).find_each(&:destroy)
    end
  end
end
```

Add the weekly schedule to `config/recurring.yml`, alongside `dead_node_preview_reaper`. Backend-
neutral, so no `command:` gate — an unviewed thumbnail is unviewed on all three.

- [ ] **Step 4: Run, mutation-check, commit**

Run: `bin/rails test test/jobs/maker/version_preview_reaper_job_test.rb` — PASS.
Mutate: change `reapable` to key on `created_at`; confirm the second test goes RED. Restore.

```bash
git add app/jobs/maker/version_preview_reaper_job.rb config/recurring.yml test/
git commit -m "Reap historical thumbnails nobody has viewed in 60 days"
```

---

### Task 4: Close the phase and the arc

- [ ] `bin/ci` green; three backend legs identical.
- [ ] Re-run `rake git_tracking:size_distribution` and confirm the threshold still looks right
      against a library that has grown since it was set.
- [ ] Check a real project's `.git` size on the share box and record it in the arc — that number is
      the whole feature's cost, and it is the one a future reader will want.
- [ ] Open the PR, then `bin/log arc --from-pr <n>` in the same breath.

## Phase 5 is done when

- The size threshold is **measured**, and the arc records the distribution it came from.
- Packs collapse at git's own `autoPackLimit`, with the new pack written before any old one is
  deleted — mutation-checked.
- Historical thumbnails age out on `last_viewed_at` — mutation-checked against the `created_at`
  spelling.
- No number in this feature is a round figure somebody picked.
