require "test_helper"

module Web
  # ADOPT IN PLACE (stage 4, S4-6; decision D1, stories 1.3 and 4.7). A folder anywhere in the
  # library becomes a project by one POST that moves nothing.
  #
  # PORT-FREE ON PURPOSE, and that is what makes it identical on all three CI legs: the door reads
  # `nodes`, writes one `maker_projects` row and at most one `dismissed_at`, and never touches
  # FileLayer — the same property docs/invariants/project-intake.md records for the discovery sweep.
  # Fixtures are therefore bare `nodes.create!` rows; ensure_library_folder! must never appear here.
  class ProjectAdoptionsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "adopt-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    def dir(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    # --- the happy path -------------------------------------------------------

    test "a folder outside Projects becomes a project that keeps its path" do
      designs = dir("d-designs", "designs")
      tray = dir("d-tray", "tray", designs.node_id)

      assert_difference "Maker::Project.count", 1 do
        post adopt_projects_path, params: { node_id: tray.node_id }
      end

      project = @user.maker_projects.order(:id).last
      assert_equal "tray", project.name
      assert_equal "tray", project.slug
      assert_equal "planning", project.status
      assert_equal tray.node_id, project.folder_node_id
      assert_redirected_to project_path(project)
      assert_match(/Made “tray” a project/, flash[:notice].to_s)
      assert_match(/files stay where they are/i, flash[:notice].to_s)
    end

    # THE FOLDER IS NOT MOVED, MINTED OR RENAMED — the whole of D1 in one assertion. `Projects/`
    # must not come into existence as a side effect of adopting something outside it, which is the
    # bug Projects::AttachmentsController#relocate shipped, one door over.
    test "adopting mints no node, moves nothing and never creates Projects/" do
      tray = dir("d-tray", "tray", dir("d-designs", "designs").node_id)
      before = @user.nodes.order(:node_id).pluck(:node_id, :name, :parent_node_id)

      post adopt_projects_path, params: { node_id: tray.node_id }

      assert_equal before, @user.nodes.order(:node_id).pluck(:node_id, :name, :parent_node_id)
      assert_nil @user.nodes.find_by(name: Maker::ProjectFolders::ROOT, parent_node_id: nil)
    end

    # AMENDMENT 4. "My NAS layout stays mine" (story 1.3) is the point of adopting in place, and a
    # sweep that re-files `tray.svg` into `design/` fifteen minutes later is the fight-the-user
    # failure §14f exists to prevent, arriving through a new door. Discovery keeps the `true`
    # default: a folder the maker put under Projects/ asked for the app's filing by being there.
    test "an adopted project has automatic filing off, and the flash says so" do
      tray = dir("d-tray", "tray")

      post adopt_projects_path, params: { node_id: tray.node_id }

      refute @user.maker_projects.order(:id).last.autofile?
      assert_match(/automatic filing is off/i, flash[:notice].to_s)
    end

    # An adopted project is one the MAKER made, so it must never wear the "New" badge.
    test "an adopted project is not marked as discovered" do
      post adopt_projects_path, params: { node_id: dir("d-tray", "tray").node_id }
      assert_nil @user.maker_projects.order(:id).last.discovered_at
    end

    # A folder DIRECTLY under Projects/ is adoptable through this door too — it is what discovery
    # would have done on its next tick, and doing it now is not a different act. The claim the row
    # takes is what makes the sweep pass over it afterwards (the row is the memory).
    test "a folder under Projects can be adopted by hand, and the sweep then passes over it" do
      root = dir("d-projects", Maker::ProjectFolders::ROOT)
      lamp = dir("d-lamp", "Desk Lamp", root.node_id)

      post adopt_projects_path, params: { node_id: lamp.node_id }
      assert_equal lamp.node_id, @user.maker_projects.order(:id).last.folder_node_id

      assert_no_difference "Maker::Project.count" do
        Maker::ProjectDiscovery.for_user(user: @user)
      end
    end

    # THE FOLDER IS A REPOSITORY ROOT — adopt it. §14f's :in_working_tree refusal already stops the
    # sweep moving a working tree's files, so this needs no special case; the assertion exists so
    # that a later refusal written for "inside a repository" cannot swallow the root as well.
    test "a folder that IS a git working tree can be adopted" do
      repo = dir("d-fw", "firmware")
      dir("d-fw-git", Library::RepoMetadata::DIR_NAME, repo.node_id)

      assert_difference "Maker::Project.count", 1 do
        post adopt_projects_path, params: { node_id: repo.node_id }
      end
    end

    # --- the refusals ---------------------------------------------------------

    test "no node_id refuses, and creates nothing" do
      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: "" }
      end
      assert_redirected_to files_path
      assert_match(/pick a folder/i, flash[:alert].to_s)
    end

    test "a file, a tombstone and another user's folder are all just 'not in your library'" do
      loose = file("n-loose", "shot.png")
      dead = dir("d-dead", "gone")
      dead.update!(deleted: true)
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: "d-theirs", name: "theirs", kind: "dir", mtime: 1, size: 0)

      [ loose.node_id, dead.node_id, theirs.node_id, "nope" ].each do |id|
        assert_no_difference "Maker::Project.count" do
          post adopt_projects_path, params: { node_id: id }
        end
        assert_match(/isn't in your library/i, flash[:alert].to_s, "for #{id}")
      end
    end

    test "a dot-folder is refused by the same rule the sweep applies" do
      git = dir("d-git", Library::RepoMetadata::DIR_NAME)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: git.node_id }
      end
      assert_match(/starts with a dot/i, flash[:alert].to_s)
    end

    test "the Projects root itself is refused" do
      root = dir("d-projects", Maker::ProjectFolders::ROOT)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: root.node_id }
      end
      assert_match(/where project folders live/i, flash[:alert].to_s)
    end

    # UNSCOPED ON STATUS — an ARCHIVED project still claims its folder, and that IS the dismissal
    # mechanism (docs/invariants/project-intake.md). Adopting a dismissed folder through this door
    # would be the "how a dismissed thing comes back" bug with a new door on it.
    test "a folder an existing project claims is refused, archived included, and names it" do
      tray = dir("d-tray", "tray")
      existing = @user.maker_projects.create!(name: "Tray", slug: "tray", folder_node_id: tray.node_id,
                                              status: "archived", archived_at: Time.current)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: tray.node_id }
      end
      assert_redirected_to project_path(existing)
      assert_match(/already the folder for Tray/, flash[:alert].to_s)
    end

    test "a folder inside another project's folder is refused and names that project" do
      lamp_dir = dir("d-lamp", "Desk Lamp")
      @user.maker_projects.create!(name: "Desk Lamp", slug: "desk-lamp", folder_node_id: lamp_dir.node_id)
      inner = dir("d-inner", "laser", lamp_dir.node_id)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: inner.node_id }
      end
      assert_match(/inside Desk Lamp/, flash[:alert].to_s)
    end

    # Adopting a repository's `src/` makes a project whose folder git owns but whose ROOT is
    # somewhere else — the README, the commits and the history all sit outside it, so S4-1's whole
    # repository card answers about the wrong tree. Point the maker at the root instead.
    test "a folder inside a working tree that is not its root is refused and names the root" do
      repo = dir("d-fw", "firmware")
      dir("d-fw-git", Library::RepoMetadata::DIR_NAME, repo.node_id)
      src = dir("d-src", "src", repo.node_id)

      assert_no_difference "Maker::Project.count" do
        post adopt_projects_path, params: { node_id: src.node_id }
      end
      assert_match(/inside the git repository “firmware”/, flash[:alert].to_s)
    end

    # --- the model that was already there -------------------------------------

    # STORY 1.3's measured friction: the seeded `*` shelf makes every top-level folder a shelf, so
    # `designs/tray` had already become a MODEL. Maker::ModelIntake stops accreting the moment a
    # project claims the folder (model_intake.rb:87-95), but the ROW SURVIVES — its own comment says
    # clearing it is Prune's job — so without this the folder is a project AND a model, forever.
    test "an auto model over the adopted folder is dismissed, and the flash says so" do
      tray = dir("d-tray", "tray", dir("d-designs", "designs").node_id)
      model = @user.maker_models.create!(title: "tray", slug: "tray", origin: "auto",
                                         auto_node_id: tray.node_id, folder_node_id: tray.node_id)

      post adopt_projects_path, params: { node_id: tray.node_id }

      assert_not_nil model.reload.dismissed_at
      assert_match(/no longer listed as a model/i, flash[:notice].to_s)
      # DISMISSED, NOT DESTROYED: the row is the memory, and destroying it makes the next sweep
      # recreate it the moment the project is deleted (docs/invariants/model-intake.md).
      assert Maker::Model.exists?(model.id)
    end

    test "an import model over the adopted folder is left alone" do
      tray = dir("d-tray", "tray")
      model = @user.maker_models.create!(title: "Tray Kit", slug: "tray-kit", origin: "import",
                                         folder_node_id: tray.node_id)

      post adopt_projects_path, params: { node_id: tray.node_id }

      assert_nil model.reload.dismissed_at, "nothing recreates an import model, so there is nothing to dismiss"
      refute_match(/no longer listed as a model/i, flash[:notice].to_s)
    end

    # --- what the adopted project's own surfaces do ---------------------------

    # The five callers of ensure_library_folder! are all no-ops for a live folder (project.rb:145-148),
    # so nothing on the project page mints `Projects/<slug>` beside the folder the maker adopted.
    # Asserted through the real page, because "it is a no-op" is a claim about code and this is a
    # claim about the request (§15: drive the real request).
    test "opening an adopted project's page mints no second folder and lists its own path" do
      tray = dir("d-tray", "tray", dir("d-designs", "designs").node_id)
      file("n-svg", "tray.svg", tray.node_id)
      post adopt_projects_path, params: { node_id: tray.node_id }
      project = @user.maker_projects.order(:id).last

      get project_path(project)

      assert_response :success
      assert_equal tray.node_id, project.reload.folder_node_id
      assert_nil @user.nodes.find_by(name: Maker::ProjectFolders::ROOT, parent_node_id: nil)
      assert_select ".attachments-panel .panel-path", text: "designs/tray"
    end

    test "requires sign-in" do
      delete destroy_user_session_path
      post adopt_projects_path, params: { node_id: "d-x" }
      assert_redirected_to new_user_session_path
    end
  end
end
