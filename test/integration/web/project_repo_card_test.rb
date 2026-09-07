require "test_helper"
require "support/git_repo_fixture"

module Web
  # STAGE 3, S3-2: the repository card on a project's page — the README rendered, the latest
  # commit, the current tag, links to the commit and history pages.
  class ProjectRepoCardTest < ActionDispatch::IntegrationTest
    include GitRepoFixture

    # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS. make_project_repo! calls
    # ensure_library_folder! -- a real mkdir through the port -- before it first reads
    # library_root (which would pin share lazily), so on the ambient s3 and chunk_remote legs the
    # mkdir hit the stub bucket (Forbidden) and the sync server's provisioning (refused): seven
    # errors per leg, green on share (found by the full gate, 2026-09-05). Same setup as
    # repo_history_flow_test.rb.
    setup { @library = use_fresh_share_library! }

    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # A real git repository INSIDE the project's own folder (Projects/<slug>/<name>), committed
    # once, reconciled into the catalog. NOT GitRepoFixture#make_repo! — that method resolves its
    # return Node with a bare `name:` lookup and no parent, which cannot tell a nested repo from a
    # same-named top-level one; this fixture is local to this file rather than widening a shared
    # helper every other git test also uses (`library_root` and `Library::ScanJob` come from
    # GitRepoFixture, included above).
    def make_project_repo!(user, project, name: "firmware", files: { "README.md" => "# Firmware\n" }, tags: [], annotated_tags: [])
      folder = project.ensure_library_folder!(user)
      dir = File.join(library_root, "Projects", project.slug, name)
      FileUtils.mkdir_p(dir)
      repo = Rugged::Repository.init_at(dir)
      files.each do |rel, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), body)
      end

      index = repo.index
      files.each_key { |rel| index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644) }
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      oid = Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "Bring up the initial firmware",
                                  parents: [], update_ref: "HEAD", author: who, committer: who)
      tags.each { |t| repo.tags.create(t, oid) }
      annotated_tags.each { |t| repo.tags.create(t, oid, message: "Release", tagger: who) }

      Library::ScanJob.new.perform(user_id: user.id)
      user.nodes.present.find_by!(parent_node_id: folder.node_id, name:, kind: "dir")
    end

    # THE PROJECT'S OWN FOLDER AS THE REPOSITORY (stage 4, S4-1): `git init` at Projects/<slug>
    # itself — the shape every real repository on the share deployment has, and the one
    # Maker::ProjectFolderListing#collect_dirs could not see (it flags CHILDREN, so the root
    # answered repo? nowhere). No FileUtils.mkdir_p: ensure_library_folder! already made the
    # directory, and init_at is happy to be handed an existing one.
    def make_root_repo!(user, project, files: { "README.md" => "# Lamp\n\nA lamp.\n" })
      folder = project.ensure_library_folder!(user)
      dir = File.join(library_root, "Projects", project.slug)
      repo = Rugged::Repository.init_at(dir)
      files.each do |rel, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), body)
      end
      index = repo.index
      files.each_key { |rel| index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644) }
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "First cut",
                            parents: [], update_ref: "HEAD", author: who, committer: who)
      Library::ScanJob.new.perform(user_id: user.id)
      user.nodes.present.find_by!(node_id: folder.node_id)
    end

    # The house mutation-check helper (project_folder_listing_test.rb and project_scan_button_test.rb
    # carry the same body; there is no shared copy in test_helper.rb, so each suite that needs it
    # defines its own). Replaces a SINGLETON method — a class's own `def self.x`, or (as used
    # below) one specific INSTANCE's `capabilities`, since `owner.singleton_class` on a plain
    # object is that object's own eigenclass.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    test "the card shows the short oid linking to the commit page, the summary and the author" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      repo = make_project_repo!(user, project)
      head_oid = Rugged::Repository.new(File.join(library_root, "Projects", "lamp", "firmware")).head.target_id

      get project_path(project)

      assert_response :success
      assert_select ".repo-card .repo-facts a[href=?]", repo_commit_path(repo.node_id), text: head_oid[0, 8]
      assert_select ".repo-card .repo-summary", text: "Bring up the initial firmware"
      assert_select ".repo-card .repo-facts", text: /Seed/
      assert_select ".repo-card a[href=?]", repo_commit_path(repo.node_id), text: "Commits"
      assert_select ".repo-card a[href=?]", repo_history_path(repo.node_id), text: "History"
    end

    test "a lightweight tag and an annotated tag on HEAD both show as badges" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      make_project_repo!(user, project, tags: [ "v1.0.0" ], annotated_tags: [ "release-1" ])

      get project_path(project)

      assert_response :success
      assert_select ".repo-card .repo-facts .badge", text: "v1.0.0"
      assert_select ".repo-card .repo-facts .badge", text: "release-1"
    end

    test "a repo with no tag says 'no tag'" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      make_project_repo!(user, project)

      get project_path(project)

      assert_response :success
      assert_select ".repo-card .repo-facts", text: /no tag/
    end

    test "the README renders headings and lists, strips raw HTML, and resolves a relative link to the file page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      readme = <<~MD
        # Firmware

        - flashes the LED
        - reads the button

        <script>alert(1)</script>

        See [the base plate](models/base.stl) for the enclosure.
      MD
      make_project_repo!(user, project, files: { "README.md" => readme, "models/base.stl" => "solid\nendsolid\n" })
      base = user.nodes.present.find_by!(name: "base.stl", kind: "file")

      get project_path(project)

      assert_response :success
      assert_select ".repo-card .markdown h1", text: "Firmware"
      assert_select ".repo-card .markdown li", text: "flashes the LED"
      assert_select ".repo-card .markdown script", count: 0
      assert_select ".repo-card .markdown a[href=?]", file_path(base.node_id), text: "the base plate"
    end

    # THE CATALOG'S SIZE GATES THE READ. The port's `read` has no byte limit, so the render cap alone
    # streamed a README of any size before cutting it (review, S3-2). A README the catalog says is
    # past README_READ_LIMIT is never read: the port's `read` is replaced with a raise for the test.
    test "a README the catalog says is huge is never read; the card says so" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      dir = make_project_repo!(user, project)
      user.nodes.find_by!(parent_node_id: dir.node_id, name: "README.md").update_column(:size, 2.megabytes)

      replacing(FileLayer.current, :read, ->(*) { raise "the port must not be read for a README past the limit" }) do
        get project_path(project)
      end

      assert_response :success
      assert_select ".repo-card .readme-note", text: /too large to show/
      assert_select ".repo-card .markdown", count: 0
    end

    test "a README beyond the cap is truncated with a note, and what precedes the cut still renders" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      huge = "# Firmware\n\n" + ("word " * 20_000) # ~100 KB, comfortably past the 64 KB cap
      make_project_repo!(user, project, files: { "README.md" => huge })

      get project_path(project)

      assert_response :success
      assert_select ".repo-card .markdown h1", text: "Firmware"
      assert_select ".repo-card .readme-note", text: /Showing the first 64 KB/
    end

    # `replacing` fakes ONE instance's `capabilities` rather than switching to the s3 backend —
    # the README still needs REAL bytes to read, and pinning s3 for one test needs the five
    # LIBRARY_S3_* stub knobs (CLAUDE.md §13) for a fact this test is not about. `FileLayer.current`
    # is memoised for the process, so stubbing the CURRENT instance's singleton `capabilities`
    # affects every caller in this request exactly as a real non-local backend would, while every
    # other read (the README's bytes) keeps hitting the real, still-share, adapter underneath.
    test "when local_worktree? is false, the card names the reason and still renders the README" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      make_project_repo!(user, project, files: { "README.md" => "# Firmware\n" })
      fake_caps = FileLayer.current.capabilities.with(local_worktree: false)

      replacing(FileLayer.current, :capabilities, -> { fake_caps }) { get project_path(project) }

      assert_response :success
      assert_select ".repo-card .repo-facts", text: /history is available where the library is a local folder/i
      assert_select ".repo-card .markdown h1", text: "Firmware"
    end

    # --- the project's OWN folder as the repository (stage 4, S4-1) ---------------

    test "a project whose own folder is the repository gets the card, Commits and History, and an honest caption" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      root = make_root_repo!(user, project)

      get project_path(project)

      assert_response :success
      assert_select ".attachments-panel .repo-card .repo-summary", text: "First cut"
      assert_select ".attachments-panel .repo-card .markdown h1", text: "Lamp"
      assert_select ".attachments-panel .panel-head a[href=?]", repo_commit_path(root.node_id), text: "Commits"
      assert_select ".attachments-panel .panel-head a[href=?]", repo_history_path(root.node_id), text: "History"
      assert_select "p.loose-note", text: /This folder is a git repository/
      assert_select "p.loose-note", text: /filed on the next sweep/, count: 0
    end

    # A PLAIN FOLDER'S README RENDERS TOO, through the same Maker::Readme reader with no git facts
    # — until S4-1 a maker with an ordinary project folder could see their own README only by
    # publishing the project (the public page has rendered one since S3-4).
    test "a plain folder's README renders on the private page, with no git facts and no Commits link" do
      user = sign_in
      project = user.maker_projects.create!(name: "Tray")
      project.ensure_library_folder!(user)
      File.write(File.join(library_root, "Projects", project.slug, "README.md"), "# Tray\n\nWalnut.\n")
      Library::ScanJob.new.perform(user_id: user.id)

      get project_path(project)

      assert_response :success
      assert_select ".attachments-panel .readme-card .markdown h1", text: "Tray"
      assert_select ".attachments-panel .readme-card .repo-facts", count: 0
      assert_select ".attachments-panel .panel-head a", text: "Commits", count: 0
      assert_select "p.loose-note", text: /filed on the next sweep/
    end
  end
end
