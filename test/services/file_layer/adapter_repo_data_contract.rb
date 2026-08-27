# The contract every adapter implementing the REPO DATA verbs must satisfy — write/read/list/delete
# of opaque bytes under a project's own `.git`, plus `repo_data_dir`, which is not a byte verb at
# all: it answers WHERE those bytes are, or nil.
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
# Three additional hooks:
#   repo_project        -> a persisted Maker::Project whose folder node exists on THIS backend.
#   second_repo_project -> a DIFFERENT persisted Maker::Project, likewise. Two projects is what
#                          makes the scoping test able to fail: with one, an adapter that ignored
#                          the project entirely would pass everything else here.
#   expects_repo_data_dir? -> does THIS backend claim a local directory? See the two tests at the
#                          bottom of this file for why the answer is DECLARED here rather than read
#                          off the verb under test, and why it has no default.
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

  # `repo_data_dir` ANSWERS ONE QUESTION FOR ONE CALLER: can this backend's repo data be operated
  # on IN PLACE by a local process, and if so where? A Pathname means yes and names the directory;
  # nil means the caller must hydrate into a cache of its own.
  #
  # IT IS A PATH-OR-NIL RATHER THAN A CAPABILITY PLUS AN ACCESSOR, deliberately: two spellings of
  # one question drift, and this port already records what that costs (§14a's `port_writable` and
  # `scannable` both exist because a coincidence was encoded once and silently became wrong).
  #
  # AND IT IS NOT `is_a?(FileLayer::Share)`. That class check is what made Library::ScanJob answer
  # false for S3 and never index the library at all (§14b); a backend answering this is stating a
  # fact about itself, which a `case adapter.class` at the call site cannot.
  #
  # THE PER-BACKEND ARM IS CHOSEN BY `expects_repo_data_dir?`, NOT BY THE VALUE UNDER TEST, and
  # that is the whole reason this hook exists. The first draft of this test read
  #
  #     return assert_nil dir, "..." if dir.nil?
  #
  # which is a guard that skips on the thing it asserts (§14e), vacuous in BOTH directions: it
  # lets any backend opt out of every assertion below simply by answering nil. Driven rather than
  # reasoned — making Share#repo_data_dir return nil left the whole share leg GREEN at 130 runs,
  # 0 failures, the second test quietly turning from a pass into a skip. A DECLARED expectation
  # makes both arms real assertions, so a regression fails whichever way it goes.
  #
  # AND IT HAS NO DEFAULT, in the module or anywhere else. An unstated default is still a claim,
  # made by whoever forgot to state one; a fourth adapter that omits the hook must fail loudly with
  # NoMethodError rather than quietly inherit share's answer or s3's.
  def test_repo_data_dir_is_a_real_directory_or_nil
    # ASKED BEFORE ANY REPO DATA EXISTS, on purpose. It is a WHERE question, so it must be
    # answerable for a project that has no repository yet, and its answer must be STABLE across the
    # write that creates one — which is what the re-ask at the bottom pins.
    dir = adapter.repo_data_dir(@user, project: repo_project)

    unless expects_repo_data_dir?
      assert_nil dir,
                 "a backend with no local filesystem must answer nil, not a path it cannot honour"
      return
    end

    assert_kind_of Pathname, dir
    adapter.write_repo_data(@user, project: repo_project, rel: "HEAD", io: StringIO.new("h\n"))
    assert dir.directory?, "#{dir} must exist once repo data has been written"
    # PROBED BEFORE IT IS READ, so the failure names the rule instead of raising Errno::ENOENT out
    # of File.read. An adapter answering the wrong directory — the library root, the project folder,
    # a sibling project's — is the regression this pair exists to catch, and it arrives here as a
    # missing file; a bare syscall error tells the next reader the disk misbehaved rather than that
    # the verb pointed somewhere else.
    assert dir.join("HEAD").file?,
           "#{dir} does not hold the bytes just written -- repo_data_dir named some directory " \
           "other than the one the repo-data verbs address"
    assert_equal "h\n", File.read(dir.join("HEAD")),
                 "the directory must be where the repo-data verbs actually put bytes"
    assert_equal dir, adapter.repo_data_dir(@user, project: repo_project),
                 "the answer must not move once the repository exists"
  end

  # A DIRECTORY PER PROJECT, never one shared. The rels are identical across projects, so a shared
  # directory would silently merge two repositories.
  #
  # THE nil BACKENDS ASSERT RATHER THAN SKIP, for the reason above: a `skip` keyed on the value
  # under test is how the first draft of this pair hid a nil-returning Share. "Both projects answer
  # nil" is a real claim about a real second project, and it is the claim that catches an adapter
  # that answered nil for one project and a path for another.
  def test_repo_data_dir_differs_per_project
    mine = adapter.repo_data_dir(@user, project: repo_project)
    theirs = adapter.repo_data_dir(@user, project: second_repo_project)

    unless expects_repo_data_dir?
      assert_nil mine
      assert_nil theirs
      return
    end

    assert_kind_of Pathname, mine
    assert_kind_of Pathname, theirs
    assert_not_equal mine, theirs
  end
end
