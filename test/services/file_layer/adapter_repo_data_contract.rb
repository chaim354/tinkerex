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
# Two additional hooks:
#   repo_project        -> a persisted Maker::Project whose folder node exists on THIS backend.
#   second_repo_project -> a DIFFERENT persisted Maker::Project, likewise. Two projects is what
#                          makes the scoping test able to fail: with one, an adapter that ignored
#                          the project entirely would pass everything else here.
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

  # A PREFIXLESS LIST IS WHAT HYDRATION CALLS, so it must return the WHOLE repo — every rel,
  # relative to the marker. A listing that quietly answers for one subtree is the "well-formed
  # lie" §14b records: the caller reads it as "these are all the objects" and hydrates an
  # incomplete repository, which fails later and elsewhere.
  def test_repo_data_lists_everything_when_no_prefix_is_given
    adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack", io: StringIO.new("a"))
    adapter.write_repo_data(@user, project: repo_project, rel: "refs/heads/main", io: StringIO.new("c"))
    adapter.write_repo_data(@user, project: repo_project, rel: "HEAD", io: StringIO.new("d"))

    assert_equal [ "HEAD", "objects/pack/a.pack", "refs/heads/main" ].sort,
                 adapter.list_repo_data(@user, project: repo_project).sort
  end

  def test_repo_data_delete_removes_it
    adapter.write_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack", io: StringIO.new("a"))
    adapter.delete_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack")

    assert_raises(FileLayer::NotFound) do
      adapter.read_repo_data(@user, project: repo_project, rel: "objects/pack/a.pack")
    end
  end

  # DELETING WHAT IS ALREADY GONE IS SUCCESS, and all three backends agree today without anything
  # saying so. A consolidation sweep that failed partway must be safe to re-run, and it cannot know
  # which of its deletes landed -- so an adapter that raised here would turn a recoverable partial
  # failure into a stuck one. Share answers it with a rescued ENOENT, s3 because DELETE on an
  # absent key is a no-op, chunk_remote because it looks the node up first; three mechanisms, one
  # promise, which is exactly the shape this file exists to hold still.
  def test_repo_data_delete_is_idempotent
    adapter.write_repo_data(@user, project: repo_project, rel: "HEAD", io: StringIO.new("keep\n"))
    adapter.delete_repo_data(@user, project: repo_project, rel: "objects/pack/never-existed.pack")

    # IT ASSERTS, RATHER THAN RESTING ON "no exception". A bare call passes for an adapter that
    # swallowed EVERY exception, cannot tell a no-op from a delete that took something else with
    # it, and trips minitest's own "Test is missing assertions" on all three legs -- a warning two
    # other files in this suite paid to keep off the run precisely because it reads as a defect.
    assert_equal "keep\n", adapter.read_repo_data(@user, project: repo_project, rel: "HEAD")
    assert_equal [ "HEAD" ], adapter.list_repo_data(@user, project: repo_project)
  end

  def test_repo_data_rejects_traversal
    assert_raises(ArgumentError) do
      adapter.write_repo_data(@user, project: repo_project, rel: "../../escape", io: StringIO.new("x"))
    end
  end

  # ONE PROJECT'S REPO CANNOT ADDRESS ANOTHER'S. The rels are identical; only the project
  # differs, so an adapter that resolved the path from anything other than the project's own
  # folder node would hand back the wrong repository's bytes with no error anywhere.
  def test_repo_data_is_scoped_to_its_own_project
    other = second_repo_project
    adapter.write_repo_data(@user, project: repo_project, rel: "HEAD", io: StringIO.new("mine\n"))
    adapter.write_repo_data(@user, project: other, rel: "HEAD", io: StringIO.new("theirs\n"))

    assert_equal "mine\n", adapter.read_repo_data(@user, project: repo_project, rel: "HEAD")
    assert_equal "theirs\n", adapter.read_repo_data(@user, project: other, rel: "HEAD")
    assert_equal [ "HEAD" ], adapter.list_repo_data(@user, project: other)
  end

  # THE ONE THAT MATTERS. See the header for why it is gated rather than unconditional.
  def test_repo_data_creates_no_catalog_entry_on_a_scannable_backend
    skip "chunk_remote mirrors the sync server; rows here are expected" unless adapter.capabilities.scannable?

    # WARMED OUTSIDE THE COUNTED WINDOW, DELIBERATELY. `repo_project` mints `Projects/` and
    # `Projects/<slug>` through Maker::LibraryFolder on its first call, and those are two ordinary
    # DIRECTORY nodes this backend is supposed to have. Counting them here would fail the
    # assertion for the fixture rather than for the write it exists to measure -- which is a
    # guard failing for the wrong reason, one step from being "fixed" by loosening it.
    project = repo_project

    assert_no_difference "Node.count" do
      adapter.write_repo_data(@user, project:, rel: "objects/pack/a.pack", io: StringIO.new("a"))
    end
    assert_empty @user.nodes.where("name LIKE ?", "%.pack"),
                 "a repo-data write must not enter the catalog on a scannable backend"
    # AND NO EXISTING ROW MAY BE REPOINTED INTO THE REPO EITHER. `Node.count` catches a CREATE and
    # nothing else, so a regression that moved a live node's storage_path under the marker would
    # build the exact ghost this file's header describes -- unpairable, tombstoned, and refusing
    # every future scan -- with the count unchanged. Two reviewers found this hole independently.
    assert_empty @user.nodes.where(deleted: false).where("storage_path LIKE ?", "%/.git/%"),
                 "no live node may point at a path inside a repository marker"
  end
end
