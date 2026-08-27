# Phase 1 — The port door: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Read first:** [`00-overview.md`](2026-08-27-git-tracked-projects-00-overview.md) for the shared
> interfaces, and the design's §2 and §6.

**Goal:** give `FileLayer` four verbs that store opaque bytes under a project's `.git` directory on
all three backends, **without ever creating a catalog entry on a backend whose catalog comes from
polling**.

**Architecture:** a fifth capability (`repo_storable`) plus four adapter methods. No git, no rugged,
no jobs, no UI. The whole phase is testable as "write bytes, read them back, list them, delete
them — and prove nothing entered `nodes`."

**Tech stack:** Rails 8, existing `FileLayer` adapters, Minitest.

---

## Why this phase exists on its own

`.git/**` is deliberately **unobserved** on share and s3 — `Library::Scanner` declines the descent,
`Library::S3Observer` drops the keys. Writing there through the ordinary `write` verb would create a
live `Node` at a path no observation can ever pair. Its tombstone then trips the mass-deletion guard
and **refuses that scan and every scan after it, permanently**. §14b records four separate wedges of
exactly this shape.

So this is not "add a write method." It is "add a write path that is structurally incapable of
producing that ghost," and the tests that matter are the ones asserting the *absence* of a node.

---

## File structure

| file | responsibility |
|---|---|
| `app/services/library/repo_metadata.rb` (modify) | one new function: compose and **validate** a rel under the marker. The only place `.git` is spelled — keep it that way |
| `app/services/file_layer/capabilities.rb` (modify) | add `repo_storable` + its argument |
| `app/services/file_layer/share.rb` (modify) | filesystem implementation |
| `app/services/file_layer/s3.rb` (modify) | bucket implementation |
| `app/services/file_layer/chunk_remote.rb` (modify) | sync-server implementation |
| `test/services/file_layer/adapter_repo_data_contract.rb` (create) | the cross-backend contract, included by all three adapter test cases |
| `test/services/library/repo_metadata_test.rb` (modify) | validation tests for the new function |

---

### Task 1: `RepoMetadata.data_rel!` — compose and reject

`Library::RepoMetadata` is already "the ONE place `.git` is spelled." The path composition belongs
there rather than duplicated into three adapters.

**It REJECTS, never normalizes.** `expand_path` would turn `a/../b` into a *valid* path and silently
address the wrong object — §14a's `key_for` rule, and it applies identically here.

**Files:**
- Modify: `app/services/library/repo_metadata.rb`
- Test: `test/services/library/repo_metadata_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/library/repo_metadata_test.rb — append inside the existing class
test "data_rel! composes a rel beneath the marker" do
  assert_equal "Projects/lamp/.git/objects/pack/p.pack",
               Library::RepoMetadata.data_rel!("Projects/lamp", "objects/pack/p.pack")
end

test "data_rel! treats a blank folder rel as the library root" do
  assert_equal ".git/HEAD", Library::RepoMetadata.data_rel!("", "HEAD")
  assert_equal ".git/HEAD", Library::RepoMetadata.data_rel!(nil, "HEAD")
end

# REJECTS, never normalizes — see the header. Each of these would otherwise address
# a path outside the project's own .git.
test "data_rel! rejects traversal, absolute paths and empty rels" do
  [ "../escape", "objects/../../escape", "/etc/passwd", "", "  ", "./HEAD" ].each do |bad|
    assert_raises(ArgumentError, "expected #{bad.inspect} to be refused") do
      Library::RepoMetadata.data_rel!("Projects/lamp", bad)
    end
  end
end

# A caller must not be able to smuggle a second marker in and address ANOTHER repo.
test "data_rel! rejects a rel that contains the marker itself" do
  assert_raises(ArgumentError) do
    Library::RepoMetadata.data_rel!("Projects/lamp", ".git/config")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/services/library/repo_metadata_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'data_rel!' for Library::RepoMetadata`

- [ ] **Step 3: Implement**

```ruby
# app/services/library/repo_metadata.rb — add inside `module RepoMetadata`, after `internal?`

    # Compose the library-relative path of one file inside a project's own `.git`, given the
    # project folder's rel and a path relative to the marker ("HEAD", "refs/heads/main",
    # "objects/pack/pack-abc.pack").
    #
    # IT REJECTS, IT NEVER NORMALIZES, and that is the same rule FileLayer::S3#key_for carries for
    # the same reason: `expand_path` would turn "objects/../../escape" into a VALID path, and the
    # caller would then read or overwrite a file outside this project's repository with no error
    # anywhere. A refusal is recoverable; a silent wrong address is not.
    #
    # A REL CONTAINING THE MARKER IS REFUSED TOO. Without that, ".git/config" composes to
    # "<folder>/.git/.git/config" — harmless — but "../other/.git/config" style smuggling is not,
    # and refusing the segment outright is one rule instead of two.
    #
    # BLANK FOLDER REL MEANS THE LIBRARY ROOT, matching the `parent_node_id: nil` convention the
    # adapter contracts already use: a project folder at the top of the library composes to
    # ".git/HEAD", not "/.git/HEAD".
    def self.data_rel!(folder_rel, rel)
      rel = rel.to_s
      segments = rel.split("/")

      if rel.strip.empty? || rel.start_with?("/") ||
         segments.any? { |s| s.empty? || s == "." || s == ".." || s == DIR_NAME }
        raise ArgumentError, "#{rel.inspect} is not a valid path inside a repository"
      end

      [ folder_rel.presence, DIR_NAME, rel ].compact.join("/")
    end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/services/library/repo_metadata_test.rb`
Expected: PASS, all tests.

- [ ] **Step 5: Mutation-check the rejection**

Temporarily replace the `raise` line with `rel = File.expand_path(rel, "/").delete_prefix("/")`.
Run the test file again.
Expected: the traversal test goes **RED**. Restore the guard, confirm green again.

This is §15's rule and it is not optional: a guard that has never failed has not been shown to work.

- [ ] **Step 6: Commit**

```bash
git add app/services/library/repo_metadata.rb test/services/library/repo_metadata_test.rb
git commit -m "RepoMetadata.data_rel!: compose a path inside a project repo, rejecting traversal"
```

---

### Task 2: The `repo_storable` capability

**Files:**
- Modify: `app/services/file_layer/capabilities.rb`
- Modify: `app/services/file_layer/share.rb`, `s3.rb`, `chunk_remote.rb` (their `capabilities`)
- Test: `test/services/file_layer/value_objects_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/file_layer/value_objects_test.rb — append
test "repo_storable is true on every backend we ship" do
  caps = FileLayer::Capabilities.new(versioned: false, syncable: false, presignable: false,
                                     scannable: true, port_writable: true, dir_deletable: false,
                                     repo_storable: true)
  assert caps.repo_storable?
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/file_layer/value_objects_test.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :repo_storable`

- [ ] **Step 3: Implement**

```ruby
# app/services/file_layer/capabilities.rb — append this comment above the Data.define,
# then add the member.

  # REPO_STORABLE answers ONE question:
  #
  #     can this backend hold opaque bytes OUTSIDE the catalog?
  #
  # It is true on all three backends today, and per this file's own standing warning that is
  # THREE SAMPLES, NOT AN IDENTITY. The distinction has to be argued, because it agrees with
  # `scannable` on share and s3 and disagrees with nothing:
  #
  #   scannable      asks where the CATALOG comes from
  #   port_writable  asks which door BYTES go in
  #   repo_storable  asks whether bytes can be stored with NO catalog entry at all
  #
  # A read-only backend — an archive mount, a published bucket — would answer false here while
  # still answering true to `scannable`, because it can be indexed and cannot be written to. That
  # is the backend that splits them, and it is the reason this is not spelled `scannable`.
  #
  # WHAT IT DOES NOT MEAN: it is not "supports git". Nothing about git is visible at the port.
  Capabilities = Data.define(:versioned, :syncable, :presignable, :scannable, :port_writable,
                             :dir_deletable, :repo_storable) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
    def scannable? = scannable
    def port_writable? = port_writable
    def dir_deletable? = dir_deletable
    def repo_storable? = repo_storable
  end
```

Then add `repo_storable: true` to the `Capabilities.new(...)` call in each of `share.rb`, `s3.rb`
and `chunk_remote.rb`.

- [ ] **Step 4: Run the full suite to catch every construction site**

Run: `bin/rails test`
Expected: PASS. A missing-keyword `ArgumentError` names any `Capabilities.new` you missed —
including ones in test fixtures.

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer/ test/services/file_layer/value_objects_test.rb
git commit -m "FileLayer::Capabilities: add repo_storable"
```

---

### Task 3: The shared contract — write it before any adapter

Writing the contract first means every adapter is measured against the same statements, which is how
`adapter_contract.rb` and `adapter_mutation_contract.rb` already work here.

**Files:**
- Create: `test/services/file_layer/adapter_repo_data_contract.rb`

- [ ] **Step 1: Write the contract**

```ruby
# test/services/file_layer/adapter_repo_data_contract.rb

# The contract every adapter implementing the REPO DATA verbs must satisfy — write/read/list/delete
# of opaque bytes under a project's own `.git`.
#
# THE ASSERTION THAT MATTERS IS THE ABSENCE OF A NODE, and it is gated on `scannable?` rather than
# asserted unconditionally, because the question is not "does a row exist" but "can the catalog
# disagree with the store":
#
#   share, s3 (scannable)      the catalog comes from POLLING, and `.git/**` is never observed. A
#                              row here is a ghost no scan can pair; its tombstone trips the
#                              mass-deletion guard and refuses that scan AND EVERY SCAN AFTER IT.
#                              §14b records four wedges of this shape. So: NO ROW, ever.
#   chunk_remote (not scannable) the catalog MIRRORS the sync server. There is no scan to
#                              disagree with, and §14b already records that the desktop client
#                              syncs `.git` rows whether this app likes it or not. Rows here are
#                              expected and harmless.
#
# Gating on `scannable?` states that argument. Asserting "no row" unconditionally would fail
# chunk_remote for doing the right thing; asserting nothing would let a share regression through.
#
# Hooks the including test case must already define (from adapter_contract.rb): `adapter`, `@user`.
# One additional hook:
#   repo_project -> a persisted Maker::Project whose folder node exists on THIS backend.
module AdapterRepoDataContract
  def test_repo_data_round_trips
    adapter.write_repo_data(@user, project: repo_project, rel: "HEAD", io: StringIO.new("ref: refs/heads/main\n"))

    assert_equal "ref: refs/heads/main\n", adapter.read_repo_data(@user, project: repo_project, rel: "HEAD")
  end

  def test_repo_data_round_trips_binary_content
    # A packfile is binary and NUL-heavy. A round trip through a String that has picked up an
    # encoding or a newline translation corrupts it silently, so assert bytes, not equality of
    # some decoded form.
    bytes = "PACK\x00\x02\xFF\x00binary\x00".b
    adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/p.pack", io: StringIO.new(bytes))

    got = adapter.read_repo_data(@user, project: repo_project, rel: "objects/pack/p.pack")
    assert_equal bytes.bytesize, got.bytesize
    assert_equal bytes, got.b
  end

  def test_repo_data_overwrites_in_place
    # refs/heads/main is rewritten on every commit. An adapter that refused a clobber here — as
    # the ordinary `write` verb correctly does — would make the second commit impossible.
    adapter.write_repo_data(@user, project: repo_project, rel: "refs/heads/main", io: StringIO.new("aaa\n"))
    adapter.write_repo_data(@user, project: repo_project, rel: "refs/heads/main", io: StringIO.new("bbb\n"))

    assert_equal "bbb\n", adapter.read_repo_data(@user, project: repo_project, rel: "refs/heads/main")
  end

  def test_repo_data_missing_rel_raises_not_found
    assert_raises(FileLayer::NotFound) do
      adapter.read_repo_data(@user, project: repo_project, rel: "objects/pack/absent.pack")
    end
  end

  def test_repo_data_lists_by_prefix
    adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack", io: StringIO.new("a"))
    adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/b.idx",  io: StringIO.new("b"))
    adapter.write_repo_data(@user, project: repo_project, rel: "refs/heads/main",      io: StringIO.new("c"))

    assert_equal [ "objects/pack/a.pack", "objects/pack/b.idx" ].sort,
                 adapter.list_repo_data(@user, project: repo_project, prefix: "objects/pack").sort
  end

  def test_repo_data_delete_removes_it
    adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack", io: StringIO.new("a"))
    adapter.delete_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack")

    assert_raises(FileLayer::NotFound) do
      adapter.read_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack")
    end
  end

  def test_repo_data_rejects_traversal
    assert_raises(ArgumentError) do
      adapter.write_repo_data(@user, project: repo_project, rel: "../../escape", io: StringIO.new("x"))
    end
  end

  # THE ONE THAT MATTERS. See the header for why it is gated rather than unconditional.
  def test_repo_data_creates_no_catalog_entry_on_a_scannable_backend
    skip "chunk_remote mirrors the sync server; rows here are expected" unless adapter.capabilities.scannable?

    assert_no_difference "Node.count" do
      adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack", io: StringIO.new("a"))
    end
    assert_empty @user.nodes.where("name LIKE ?", "%.pack"),
                 "a repo-data write must not enter the catalog on a scannable backend"
  end
end
```

- [ ] **Step 2: Commit the contract alone**

It has no includers yet, so nothing runs. Committing it separately keeps the next three diffs
readable.

```bash
git add test/services/file_layer/adapter_repo_data_contract.rb
git commit -m "Contract for the repo-data port verbs, with the no-catalog-entry assertion"
```

---

### Task 4: Share implements the verbs

**Files:**
- Modify: `app/services/file_layer/share.rb`
- Modify: `test/services/file_layer/share_test.rb`

- [ ] **Step 1: Wire the contract into Share's test case**

```ruby
# test/services/file_layer/share_test.rb — inside the existing test class
include AdapterRepoDataContract

# The contract's one extra hook. `Maker::Project#ensure_library_folder!` mints Projects/<slug>
# through the port, so the folder node has a real storage_path on this backend.
def repo_project
  @repo_project ||= begin
    p = @user.maker_projects.create!(title: "Repo Project")
    p.ensure_library_folder!(@user)
    p
  end
end
```

Add `require_relative "adapter_repo_data_contract"` beside the existing contract requires.

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/file_layer/share_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'write_repo_data'`

- [ ] **Step 3: Implement**

```ruby
# app/services/file_layer/share.rb — add as PUBLIC methods, beside the other verbs

    # THE REPO-DATA VERBS. Opaque bytes under a project's own `.git`, deliberately NOT catalogued.
    #
    # THEY DO NOT GO THROUGH #observable!, AND THAT IS THE POINT RATHER THAN AN OVERSIGHT.
    # `observable!` refuses everything at or beneath the marker, precisely so the ordinary write
    # path can never leave a live node at a path no scan can pair. These verbs create no node at
    # all, so the ghost that guard exists to prevent is unreachable from here — and routing them
    # through it would refuse the one caller that is safe.
    #
    # NO CLOBBER REFUSAL EITHER. `refs/heads/main` is rewritten on every commit; a refusal would
    # make the second commit impossible. The ordinary #write keeps its refusal, for its own
    # reasons, and these are a different door.
    def write_repo_data(user, project:, rel:, io:)
      path = repo_data_path(user, project, rel)
      FileUtils.mkdir_p(path.dirname)
      # Temp-then-rename so a reader never sees a half-written pack. Same argument #write makes,
      # and the temp name uses the Scanner's own prefix constant rather than a second literal.
      tmp = path.dirname.join("#{Library::Scanner::TEMP_PREFIX}#{SecureRandom.hex(8)}")
      begin
        File.open(tmp, "wb") { |f| IO.copy_stream(io, f) }
        File.rename(tmp, path)
      ensure
        File.unlink(tmp) if File.exist?(tmp)
      end
      nil
    rescue SystemCallError => e
      raise FetchError, "repo write failed for #{rel.inspect}: #{e.message}"
    end

    def read_repo_data(user, project:, rel:)
      path = repo_data_path(user, project, rel)
      File.binread(path)
    rescue Errno::ENOENT
      # NotFound, not FetchError: this rel genuinely is not there and a retry cannot change it.
      raise NotFound, "no repo data at #{rel.inspect}"
    rescue SystemCallError => e
      # An unmounted share must never read as "permanently gone" (§14a).
      raise FetchError, "repo read failed for #{rel.inspect}: #{e.message}"
    end

    def list_repo_data(user, project:, prefix: nil)
      root = repo_data_root(user, project)
      base = prefix.present? ? repo_data_path(user, project, prefix) : root
      return [] unless base.directory?

      Dir.glob("**/*", base: base.to_s)
         .reject { |r| File.directory?(base.join(r)) }
         .map { |r| prefix.present? ? "#{prefix}/#{r}" : r }
    rescue SystemCallError => e
      raise FetchError, "repo list failed: #{e.message}"
    end

    def delete_repo_data(user, project:, rel:)
      File.unlink(repo_data_path(user, project, rel))
      nil
    rescue Errno::ENOENT
      nil # deleting what is already gone is success, not an error
    rescue SystemCallError => e
      raise FetchError, "repo delete failed for #{rel.inspect}: #{e.message}"
    end
```

```ruby
# app/services/file_layer/share.rb — add to the PRIVATE section

    def repo_data_root(user, project)
      resolve_inside!(project_folder_rel(user, project) + "/" + Library::RepoMetadata::DIR_NAME)
    end

    def repo_data_path(user, project, rel)
      resolve_inside!(Library::RepoMetadata.data_rel!(project_folder_rel(user, project), rel))
    end

    # The project's folder as a library-relative path. Raises rather than defaulting to the
    # library ROOT if the folder has no storage_path — #absolute_path's own landmine, where a
    # NULL storage_path once resolved to the root and handed a DIRECTORY to send_file.
    def project_folder_rel(user, project)
      node = live_node!(user, project.folder_node_id)
      rel = node.storage_path.to_s
      raise NotFound, "project #{project.id} folder has no storage_path" if rel.blank?
      rel
    end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/file_layer/share_test.rb`
Expected: PASS, including `test_repo_data_creates_no_catalog_entry_on_a_scannable_backend`.

- [ ] **Step 5: Mutation-check the no-catalog guard**

This is the guard the whole phase exists for, so prove it can fail. Temporarily add to
`write_repo_data`, just before `nil`:

```ruby
user.nodes.create!(node_id: SecureRandom.uuid, name: File.basename(rel), kind: "file")
```

Run: `bin/rails test test/services/file_layer/share_test.rb`
Expected: `test_repo_data_creates_no_catalog_entry_on_a_scannable_backend` goes **RED**.
Remove the line, confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/services/file_layer/share.rb test/services/file_layer/share_test.rb
git commit -m "FileLayer::Share: repo-data verbs, catalog untouched"
```

---

### Task 5: S3 implements the verbs

**Files:**
- Modify: `app/services/file_layer/s3.rb`
- Modify: `test/services/file_layer/s3_test.rb`

- [ ] **Step 1: Wire the contract into S3's test case**

```ruby
# test/services/file_layer/s3_test.rb — inside the existing test class
include AdapterRepoDataContract

def repo_project
  @repo_project ||= begin
    p = @user.maker_projects.create!(title: "Repo Project")
    p.ensure_library_folder!(@user)
    p
  end
end
```

Add `require_relative "adapter_repo_data_contract"` beside the existing contract requires.

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_BACKEND=s3 bin/rails test test/services/file_layer/s3_test.rb`
(The s3 leg needs the five `LIBRARY_S3_*` stub knobs — copy them from `.github/workflows/ci.yml`'s
`test-s3-backend` job.)
Expected: FAIL — `NoMethodError: undefined method 'write_repo_data'`

- [ ] **Step 3: Implement**

```ruby
# app/services/file_layer/s3.rb — add as PUBLIC methods, beside the other verbs

    # THE REPO-DATA VERBS. See FileLayer::Share for the argument; the same rules hold here and
    # the S3Observer is the half that drops these keys from the catalog.
    #
    # NO TEMP-AND-RENAME, matching #write and for the identical reason: put_object is ATOMIC, so a
    # temp key would add a second, unobservable ghost and buy nothing. A reader never sees a
    # half-written object.
    def write_repo_data(user, project:, rel:, io:)
      @client.put_object(bucket: @bucket, key: repo_data_key(user, project, rel), body: io.read)
      nil
    rescue Aws::S3::Errors::ServiceError => e
      raise FetchError, "repo write failed for #{rel.inspect}: #{e.message}"
    end

    def read_repo_data(user, project:, rel:)
      @client.get_object(bucket: @bucket, key: repo_data_key(user, project, rel)).body.read
    rescue Aws::S3::Errors::NoSuchKey
      raise NotFound, "no repo data at #{rel.inspect}"
    rescue Aws::S3::Errors::ServiceError => e
      raise FetchError, "repo read failed for #{rel.inspect}: #{e.message}"
    end

    def list_repo_data(user, project:, prefix: nil)
      root = repo_data_key(user, project, prefix.presence || "x").delete_suffix(prefix.presence || "x")
      out = []
      token = nil
      loop do
        resp = @client.list_objects_v2(bucket: @bucket, prefix: root, continuation_token: token)
        resp.contents.each { |o| out << o.key.delete_prefix(root) }
        # COMPLETE OR NOTHING. A truncated listing is a well-formed lie (§14b): a caller would
        # read it as "these are all the packs" and hydrate an incomplete repo.
        break unless resp.is_truncated
        token = resp.next_continuation_token
      end
      out.map { |r| prefix.present? ? "#{prefix}/#{r}" : r }
    rescue Aws::S3::Errors::ServiceError => e
      raise FetchError, "repo list failed: #{e.message}"
    end

    def delete_repo_data(user, project:, rel:)
      @client.delete_object(bucket: @bucket, key: repo_data_key(user, project, rel))
      nil
    rescue Aws::S3::Errors::ServiceError => e
      raise FetchError, "repo delete failed for #{rel.inspect}: #{e.message}"
    end
```

```ruby
# app/services/file_layer/s3.rb — add to the PRIVATE section

    def repo_data_key(user, project, rel)
      key_for_rel(Library::RepoMetadata.data_rel!(project_folder_rel(user, project), rel))
    end

    def project_folder_rel(user, project)
      node = live_node!(user, project.folder_node_id)
      rel = node.storage_path.to_s
      raise NotFound, "project #{project.id} folder has no storage_path" if rel.blank?
      rel
    end
```

- [ ] **Step 4: Run to verify it passes**

Run: `LIBRARY_BACKEND=s3 bin/rails test test/services/file_layer/s3_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check the pagination guard**

Temporarily change `break unless resp.is_truncated` to `break`. Add a test that stubs a truncated
first page, and confirm it goes RED — a silently short listing is the failure mode §14b calls "a
well-formed lie."

```ruby
test "list_repo_data refuses to return a truncated listing as complete" do
  30.times { |i| adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/p#{i}.pack", io: StringIO.new("x")) }
  assert_equal 30, adapter.list_repo_data(@user, project: repo_project, prefix: "objects/pack").size
end
```

(If the S3 fake does not paginate at 30, set its page size down for this test — the assertion is
about following the continuation token, not about the number.)

- [ ] **Step 6: Commit**

```bash
git add app/services/file_layer/s3.rb test/services/file_layer/s3_test.rb
git commit -m "FileLayer::S3: repo-data verbs, listing complete-or-nothing"
```

---

### Task 6: ChunkRemote implements the verbs

Here the data **is** catalogued, and that is correct — the `nodes` table mirrors the sync server
rather than a scan, so there is no scan to disagree with, and §14b already records that the desktop
client syncs `.git` rows regardless.

**Files:**
- Modify: `app/services/file_layer/chunk_remote.rb`
- Modify: `test/services/file_layer/chunk_remote/` (the adapter's test case)

- [ ] **Step 1: Wire the contract in**

```ruby
# in the ChunkRemote adapter test case
include AdapterRepoDataContract

def repo_project
  @repo_project ||= begin
    p = @user.maker_projects.create!(title: "Repo Project")
    p.ensure_library_folder!(@user)
    p
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/ci test-chunk-remote` (needs `../tinkerex-sync`; from a worktree set `TINKEREX_SYNC_DIR`).
Expected: FAIL — `NoMethodError: undefined method 'write_repo_data'`

- [ ] **Step 3: Implement**

```ruby
# app/services/file_layer/chunk_remote.rb — add as PUBLIC methods

    # THE REPO-DATA VERBS ON chunk_remote. Unlike share and s3 these DO create nodes, and that is
    # correct rather than a leak: this backend's catalog MIRRORS the sync server, so there is no
    # scan to disagree with, and §14b already records that the desktop client syncs `.git` rows
    # whether this app likes it or not. The contract's no-catalog-entry assertion is gated on
    # `scannable?` for exactly this reason — see its header.
    #
    # They reuse the existing verbs rather than opening a second write path: a repo file is an
    # ordinary file as far as the sync server is concerned.
    def write_repo_data(user, project:, rel:, io:)
      safe = Library::RepoMetadata.data_rel!(nil, rel) # validate; the folder is resolved by node
      parent = ensure_repo_dirs(user, project, File.dirname(safe))
      bytes = io.read
      existing = user.nodes.present.find_by(parent_node_id: parent.node_id, name: File.basename(safe))
      commit = begin_upload(user, parent_node_id: parent.node_id, name: File.basename(safe),
                            size: bytes.bytesize, manifest: manifest_for(bytes),
                            node_id: existing&.node_id)
      put_chunk(user, commit_id: commit.commit_id, hash: Digest::SHA256.hexdigest(bytes), body: bytes)
      finalize_upload(user, commit_id: commit.commit_id, broadcast: false)
      nil
    end

    def read_repo_data(user, project:, rel:)
      node = repo_data_node(user, project, rel) or raise NotFound, "no repo data at #{rel.inspect}"
      read(user, node_id: node.node_id)
    end

    def list_repo_data(user, project:, prefix: nil)
      root = repo_root_node(user, project) or return []
      walk_repo_tree(user, root, "").select { |r| prefix.blank? || r.start_with?("#{prefix}/") }
    end

    def delete_repo_data(user, project:, rel:)
      node = repo_data_node(user, project, rel)
      delete(user, node_id: node.node_id) if node
      nil
    end
```

Implement `ensure_repo_dirs`, `repo_root_node`, `repo_data_node`, `walk_repo_tree` and
`manifest_for` privately, using the adapter's existing `mkdir` and mirror queries.
`finalize_upload(broadcast: false)` matches `Maker::Addons::LibraryOutput`: repo bookkeeping is not
a user-visible file change and must not nudge devices (§14a).

- [ ] **Step 4: Run to verify it passes**

Run: `bin/ci test-chunk-remote`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer/chunk_remote.rb test/services/file_layer/chunk_remote/
git commit -m "FileLayer::ChunkRemote: repo-data verbs over the sync server"
```

---

### Task 7: Close the phase

- [ ] **Step 1: Run every gate**

Run: `bin/ci`
Expected: all seven gates green.

- [ ] **Step 2: Compare the three backend legs**

`bin/ci` prints run counts for `test`, `test-s3` and `test-chunk-remote` and **never compares them**
— that has always been a human read. They must be **identical**. A ±2 assertion difference is the
known flap (`tinkerex#131`); a structural difference means a test depends on ambient
`LIBRARY_BACKEND` and is a real bug.

- [ ] **Step 3: Open the PR and file the arc in the same breath**

```bash
gh pr create --title "Phase 1: the repo-data port door" --body "..."
bin/log arc --from-pr <n>
```

The arc is part of the work, not a tidy-up afterwards (§15). Deferred, it does not happen.

---

## Phase 1 is done when

- All four verbs answer on all three backends, driven by one shared contract.
- A repo-data write on share and s3 creates **no `Node`** — and that assertion has been
  mutation-checked to prove it can fail.
- `Library::RepoMetadata` is still the only place `.git` is spelled.
- No git library, no job, no UI, no schema change.
