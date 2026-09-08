require "test_helper"
require "support/git_repo_fixture"

module Web
  # STAGE 4, S4-4 (story 5.3; spec §2 D3): the README editor on the project page's README card, for
  # ANY project — a plain folder as much as a working tree.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS, for the reason
  # project_repo_card_test.rb records at its own setup: these tests write real bytes through the
  # port, and on the ambient s3 and chunk_remote legs the folder mkdir hits the stub bucket and the
  # sync server's provisioning. Pinning share is what makes the three legs report identical counts.
  class ReadmeEditTest < ActionDispatch::IntegrationTest
    include GitRepoFixture

    setup { @library = use_fresh_share_library! }

    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "readme@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # The house mutation-check helper (project_repo_card_test.rb and project_folder_listing_test.rb
    # carry the same body; there is no shared copy in test_helper.rb, so each suite that needs it
    # defines its own). Replaces a SINGLETON method for the block's duration.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def project_with_folder!(user, name: "Desk Lamp", readme: nil)
      project = user.maker_projects.create!(name:)
      project.ensure_library_folder!(user)
      File.write(File.join(library_root, "Projects", project.slug, "README.md"), readme) if readme
      Library::ScanJob.new.perform(user_id: user.id)
      project
    end

    def readme_node(user, project)
      folder = user.nodes.present.find_by!(node_id: project.reload.folder_node_id)
      user.nodes.present.find_by(parent_node_id: folder.node_id, name: "README.md")
    end

    def token_for(user, node) = FileLayer.current.stat(user, node_id: node.node_id)&.content_token

    # --- the card ------------------------------------------------------------------------------

    test "a folder with a README offers an Edit control carrying the blob url and the current token" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Lamp\n\nWalnut.\n")
      node = readme_node(user, project)

      get project_path(project)

      assert_response :success
      assert_select ".readme-card .readme-editor[data-controller=readme]"
      assert_select ".readme-editor[data-readme-url-value=?]", blob_file_path(node.node_id)
      assert_select ".readme-editor summary", text: "Edit README"
      assert_select ".readme-editor input[name=base_token][value=?]", token_for(user, node)
      assert_select ".readme-editor textarea[name=content][disabled=disabled]"
    end

    # THE TEMPLATE'S TEXTAREA IS LIVE FROM THE FIRST BYTE. With no README there is nothing a blank
    # submit could destroy and nothing to fetch, so the plain form must work with no JavaScript at
    # all — a disabled control is dropped from the submission, which would make the no-JS Save
    # post an empty body and be refused for the template it was rendered with.
    test "a folder with no README offers Write a README, pre-filled with the template and no token" do
      user = sign_in
      project = project_with_folder!(user)

      get project_path(project)

      assert_select ".readme-editor summary", text: "Write a README"
      assert_select ".readme-editor[data-readme-url-value=?]", ""
      assert_select ".readme-editor textarea[name=content]", /\A# Desk Lamp/
      assert_select ".readme-editor textarea[name=content]", /## Build log/
      assert_select ".readme-editor textarea[name=content][disabled]", 0
      assert_select ".readme-editor input[name=base_token]", 0
    end

    # `ProjectsController#show` re-mints a missing folder (`ensure_library_folder!`, best-effort),
    # so "a project with no folder" is reachable only when that mint FAILS — an unmounted share, a
    # bucket blip — which is the real case: the page renders, the listing is unavailable, and an
    # editor offered there would post into a folder that does not exist.
    test "a project with no library folder offers no editor at all" do
      user = sign_in
      project = user.maker_projects.create!(name: "Folderless")
      project.update_column(:folder_node_id, nil)

      replacing(Maker::LibraryFolder, :ensure_path!, ->(*) { raise FileLayer::FetchError, "share not mounted" }) do
        get project_path(project)
      end

      assert_response :success
      assert_select ".readme-editor", 0
    end

    # --- the save ------------------------------------------------------------------------------

    test "saving an existing README rewrites it in place, keeps the node, and the card shows it" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)

      patch project_readme_path(project),
            params: { content: "# Lamp\n\n## Build steps\n", base_token: token_for(user, node) }

      assert_redirected_to project_path(project)
      assert_equal "README saved.", flash[:notice]
      assert_equal node.node_id, readme_node(user, project).node_id, "a replace must reuse the node (§14a)"
      assert_equal "# Lamp\n\n## Build steps\n", FileLayer.current.read(user, node_id: node.node_id)

      follow_redirect!
      assert_select ".readme-card .markdown h2[id=user-content-build-steps]", text: "Build steps"
    end

    test "saving with no README creates README.md at the folder root" do
      user = sign_in
      project = project_with_folder!(user)

      patch project_readme_path(project), params: { content: "# Fresh\n" }

      assert_redirected_to project_path(project)
      node = readme_node(user, project)
      assert node, "README.md should exist at the folder root"
      assert_equal "# Fresh\n", FileLayer.current.read(user, node_id: node.node_id)
    end

    test "a stale token is refused and the bytes on disk are untouched" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)

      patch project_readme_path(project), params: { content: "# New\n", base_token: "stale" }

      assert_redirected_to project_path(project)
      assert_match(/changed since you opened it/, flash[:alert])
      assert_equal "# Old\n", FileLayer.current.read(user, node_id: node.node_id)
    end

    # THE SAME REFUSAL, FOR THE HALF THE CATALOG CANNOT SEE. The token above is nonsense, so the row
    # arm of Maker::TextSave's check catches it; here the token is the REAL one the card rendered
    # and the row still agrees with it, because the README changed on disk with no scan behind it.
    # That was an overwrite until `expect_token:` reached the port (§14a) — and on a share there is
    # no version to restore the lost text from.
    #
    # THIS DOOR ANSWERS WITH A REDIRECT AND AN ALERT, NOT A 409, which is not an inconsistency to
    # tidy: it always redirects (see the controller's header — the point of the feature is landing
    # back on the project page), and the message is the one the stale test above asserts, because
    # both arms of the check produce the same refusal.
    test "a README save racing a desktop edit the scan has not seen keeps the desktop bytes" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)
      on_disk = File.join(library_root, "Projects", project.slug, "README.md")
      File.write(on_disk, "# From the desktop\n")

      patch project_readme_path(project), params: { content: "# From the browser\n",
                                                    base_token: token_for(user, node) }

      assert_redirected_to project_path(project)
      assert_match(/changed since you opened it/, flash[:alert])
      assert_equal "# From the desktop\n", File.read(on_disk),
                   "the edit the catalog had not observed must survive the save that raced it"
    end

    test "a blank body is refused rather than emptying the README" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)

      patch project_readme_path(project), params: { content: "  ", base_token: token_for(user, node) }

      assert_match(/needs some text/, flash[:alert])
      assert_equal "# Old\n", FileLayer.current.read(user, node_id: node.node_id)
    end

    # THE DOOR TAKES NO NODE ID, WHICH IS WHAT CONFINES D3'S EXCEPTION TO DOCUMENTATION
    # (git-editing.md). Extra params naming another file must change nothing about which file is
    # written — there is no parameter to point it somewhere else.
    test "the door writes the README and nothing else, whatever extra params are posted" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      File.write(File.join(library_root, "Projects", project.slug, "secrets.env"), "KEY=1\n")
      Library::ScanJob.new.perform(user_id: user.id)
      # LOOKED UP BY NAME, NOT UNDER THE FOLDER ROOT: the scan's intake sweep files a loose root
      # file by its role (`.env` lands in `other/`), and only a README stays put. Where the sweep
      # put it is not this test's subject; that its bytes survive the README save is.
      victim = user.nodes.present.find_by!(name: "secrets.env", kind: "file")

      patch project_readme_path(project),
            params: { content: "# New\n", base_token: token_for(user, readme_node(user, project)),
                      node_id: victim.node_id, name: "secrets.env" }

      assert_equal "KEY=1\n", FileLayer.current.read(user, node_id: victim.node_id)
      assert_equal "# New\n", FileLayer.current.read(user, node_id: readme_node(user, project).node_id)
    end

    test "another maker's project is a 404" do
      owner = sign_in("owner@example.com")
      project = project_with_folder!(owner)
      # SIGN OUT FIRST. Devise's `require_no_authentication` turns a second sign-in on a live
      # session into a redirect, so without this line the intruder never signs in and the PATCH
      # below runs as the OWNER — a 302 that reads as the 404 case having been tested.
      delete destroy_user_session_path
      sign_in("intruder@example.com")

      patch project_readme_path(project), params: { content: "# Mine now\n" }

      assert_response :not_found
    end

    # --- the trade is named --------------------------------------------------------------------

    test "share says it keeps no history; a versioned backend says nothing" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Lamp\n")

      get project_path(project)

      if FileLayer.current.capabilities.versioned?
        assert_select ".readme-editor .no-history-note", 0
      else
        assert_select ".readme-editor .no-history-note", text: /keeps no history for this file/
      end
    end

    # --- a root repository gets the same editor, plus a pending edit ----------------------------

    test "a root working tree gets the editor inside its repo card and the save records a pending edit" do
      user = sign_in
      project = user.maker_projects.create!(name: "Firmware")
      project.ensure_library_folder!(user)
      dir = File.join(library_root, "Projects", project.slug)
      repo = Rugged::Repository.init_at(dir)
      File.write(File.join(dir, "README.md"), "# Firmware\n")
      index = repo.index
      index.add(path: "README.md", oid: Rugged::Blob.from_workdir(repo, "README.md"), mode: 0o100644)
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "First", parents: [],
                            update_ref: "HEAD", author: who, committer: who)
      Library::ScanJob.new.perform(user_id: user.id)
      node = readme_node(user, project)

      get project_path(project)
      assert_select ".repo-card .readme-editor[data-controller=readme]"

      patch project_readme_path(project),
            params: { content: "# Firmware v2\n", base_token: token_for(user, node) }

      assert_equal [ node.node_id ], Maker::RepoEdit.where(user:).pluck(:node_id)
      assert_equal project.reload.folder_node_id,
                   Maker::RepoEdit.find_by(user:, node_id: node.node_id).repo_root_node_id
    end
  end
end
