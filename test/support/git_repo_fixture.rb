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
