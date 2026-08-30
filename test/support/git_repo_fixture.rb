require "rugged"

# REAL REPOSITORIES, NOT FIXTURES. tinkerex#178's evidence came from real ones, and the two cases
# that matter most — a .gitignore excluding almost everything, and a repository with no commits at
# all — are exactly the ones a hand-rolled fixture quietly omits.
module GitRepoFixture
  # Creates <library>/<name>/ as a git repository with `files`, all committed, and indexes the
  # catalog nodes for it. Returns the repository's root Node.
  def make_repo!(name: "demo", files: { "notes.md" => "old\n" }, gitignore: nil, commit: true)
    dir = File.join(library_root, name)
    FileUtils.mkdir_p(dir)
    repo = Rugged::Repository.init_at(dir)

    files.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), body)
    end
    File.write(File.join(dir, ".gitignore"), gitignore) if gitignore

    if commit
      index = repo.index
      (files.keys + (gitignore ? [ ".gitignore" ] : [])).each { |rel| index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644) }
      index.write
      Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "seed", parents: [],
                            update_ref: "HEAD",
                            author:    { name: "Seed", email: "seed@example.com", time: Time.now },
                            committer: { name: "Seed", email: "seed@example.com", time: Time.now })
    end

    # KEYWORD ARGUMENT, not positional: Library::ScanJob#perform is `perform(user_id:, root: nil)`.
    # The plan wrote `.perform(@user.id)`, which is an ArgumentError before the scan ever starts.
    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "dir")
  end

  def seed_repo_file!(rel, body)
    make_repo!(files: { rel => body })
    @user.nodes.present.find_by!(name: File.basename(rel), kind: "file")
  end

  # A FIXED, DISTINCT SECOND PER COMMIT, with a base that depends on the repository's NAME. Both
  # halves are load-bearing and neither is tidiness.
  #
  # git stores a commit time to WHOLE SECONDS, so a builder using `Time.now` gives every commit in
  # one fixture the same time, and `Rugged::SORT_DATE` breaks ties in an order libgit2 does not
  # specify -- probed on rugged 1.9.6: four same-second commits walked as c3, c0, c1, c2, so every
  # "newest first" assertion was luck. This is §15's `.to_i` trap seen from the other side.
  #
  # The NAME matters because git content-addresses commits: two repositories built with identical
  # trees, messages, authors AND times produce byte-identical commit oids -- probed: true -- so a
  # test about "an oid from another repository" would be handing this one an oid it contains.
  def fixture_commit_time(name, index) = Time.at(1_700_000_000 + (name.sum * 1_000) + index)

  # A REPOSITORY WITH MORE COMMITS THAN THE CAP. Without this every cap assertion is vacuous --
  # a walk that never reaches its limit proves nothing about the limit, and that exact shape is
  # what kept tinkerex#185 invisible.
  #
  # `touch_every` makes path filtering sparse ON PURPOSE: with it at 4, only a quarter of commits
  # touch "tracked.txt", which is what makes "the walk stopped before finding anything" a state
  # the tests can actually reach (spec part 3).
  def make_repo_with_commits!(name: "many", count: 12, touch_every: 4)
    dir = File.join(library_root, name)
    FileUtils.mkdir_p(dir)
    repo = Rugged::Repository.init_at(dir)
    parents = []
    count.times do |i|
      rel = (i % touch_every).zero? ? "tracked.txt" : "other-#{i}.txt"
      File.write(File.join(dir, rel), "v#{i}\n")
      index = repo.index
      index.read_tree(repo.head.target.tree) unless repo.head_unborn?
      index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644)
      index.write
      who = { name: "Seed", email: "s@example.com", time: fixture_commit_time(name, i) }
      oid = Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "c#{i}",
                                  parents:, update_ref: "HEAD", author: who, committer: who)
      parents = [ oid ]
    end
    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "dir")
  end

  # A REPOSITORY CONTAINING A MERGE, so "first parent only" (spec part 4) is a rule a test can
  # catch someone breaking. Without a merge commit, comparing against EVERY parent instead of the
  # first changes nothing any assertion can see, and a mutation nothing can catch is not a checked
  # mutation.
  #
  # The shape is chosen so the two spellings disagree: the merge takes the MAINLINE version of
  # tracked.txt, so it is TREESAME to its first parent and NOT to its second.
  #
  #   c0  tracked.txt = v0
  #   c1  tracked.txt = v1        (mainline)
  #   s0  side.txt added          (branched from c0; tracked.txt still v0)
  #   m   merge [c1, s0]          tracked.txt = v1, side.txt present
  #
  # first parent only -> [c1, c0]; every parent -> [m, c1] (probed). The second is wrong twice
  # over: it attributes the change to the merge as well as to c1, and it drops the ROOT commit,
  # whose `parents` is empty so `any?` is false.
  def make_repo_with_merge!(name: "merged")
    dir = File.join(library_root, name)
    FileUtils.mkdir_p(dir)
    repo = Rugged::Repository.init_at(dir)
    who = ->(i) { { name: "Seed", email: "s@example.com", time: fixture_commit_time(name, i) } }
    v0 = Rugged::Blob.from_buffer(repo, "v0\n")
    v1 = Rugged::Blob.from_buffer(repo, "v1\n")
    side = Rugged::Blob.from_buffer(repo, "s\n")

    c0 = fixture_commit!(repo, { "tracked.txt" => v0 }, message: "c0", parents: [], who: who.(0))
    c1 = fixture_commit!(repo, { "tracked.txt" => v1 }, message: "c1", parents: [ c0 ], who: who.(1))
    # NO `update_ref`: the side commit must not move HEAD, or there is no branch to merge.
    s0 = fixture_commit!(repo, { "tracked.txt" => v0, "side.txt" => side },
                         message: "s0", parents: [ c0 ], who: who.(2), update_ref: nil)
    fixture_commit!(repo, { "tracked.txt" => v1, "side.txt" => side },
                    message: "m", parents: [ c1, s0 ], who: who.(3))

    repo.checkout_head(strategy: :force) # leave a working tree that matches HEAD, as a real one does
    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "dir")
  end

  # Builds a tree from `path => blob_oid` through the index and commits it. The index is CLEARED
  # first rather than read from a parent: each caller above states the whole tree it wants, which
  # is what lets the merge's tree differ from its second parent's on purpose.
  def fixture_commit!(repo, entries, message:, parents:, who:, update_ref: "HEAD")
    index = repo.index
    index.clear
    entries.each { |rel, oid| index.add(path: rel, oid:, mode: 0o100644) }
    index.write
    Rugged::Commit.create(repo, tree: index.write_tree(repo), message:, parents:,
                          update_ref:, author: who, committer: who)
  end

  def seed_plain_file!(name, body)
    FileUtils.mkdir_p(File.join(library_root, "Loose"))
    File.write(File.join(library_root, "Loose", name), body)
    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "file")
  end

  def token_for(node) = FileLayer.current.stat(@user, node_id: node.node_id)&.content_token
  def read_back(node) = FileLayer.current.read(@user, node_id: node.node_id)

  # PINS A REAL SHARE LIBRARY, so a case that needs a working tree runs IDENTICALLY on all three
  # legs instead of varying with the ambient LIBRARY_BACKEND -- which is what keeps the run counts
  # equal (§15). The cases that must vary by backend are the ones asserting the AFFORDANCE'S
  # ABSENCE, and those deliberately do not call this (Task 10 Step 6).
  def library_root = (@library ||= use_fresh_share_library!).to_s

  # `Rugged::Repository#status` REQUIRES A BLOCK -- without one it raises
  # "A block was expected for iterating through the repository contents." (rugged 1.9.6, probed).
  # So no caller may write `repo.status.count { }` or `repo.status.select { }`; collect first.
  def git_statuses(repo)
    out = {}
    repo.status { |rel, flags| out[rel] = flags }
    out
  end
end
