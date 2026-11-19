require "test_helper"
require "support/git_repo_fixture"

module Web
  # THE TIDY-UP LIST ON THE PAGE AND THROUGH ITS DOOR (the Shop manual's §9, 2026-11-19): the plate
  # renders only while it holds an undismissed suggestion, numbers its cells, links each to where the
  # maker fixes it, and the contents column gains a "Tidy up" row with the plate's count. Dismiss posts
  # the kind and the subject; the SERVER finds the suggestion and stores the state it computed, so a
  # browser cannot dismiss a suggestion the page does not raise, nor pin one in a state of its choosing.
  # Home carries the OUT OF DATE row and loses it once dismissed.
  #
  # Catalog rows only (`project_folder_rows!`), so every case runs the same on every leg, except the
  # one about a repository, which pins a share library through GitRepoFixture on every leg alike.
  class ProjectTidyUpTest < ActionDispatch::IntegrationTest
    include GitRepoFixture

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tidy-page@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Catan", status: "active")
    end

    def dir!(name, parent)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent.node_id, mtime: 1, size: 0)
    end

    def file!(name, parent, mtime: 1_000)
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent.node_id, size: 1, mtime:,
                          content_hash: "h-#{id}", current_version_id: "v-#{id}")
    end

    # One loose file the next pass cannot file, and one export older than its source.
    def two_suggestions!
      folder = project_folder_rows!(@user, @project)
      design = dir!("design", folder)
      file!("harbor.svg", design)
      @loose = file!("harbor.svg", folder)
      laser = dir!("laser", folder)
      @source = file!("hex tiles.lbrn2", laser, mtime: 2_000)
      @export = file!("hex tiles.svg", design, mtime: 1_000)
      @user.maker_file_links.create!(from_node_id: @export.node_id, to_node_id: @source.node_id, kind: "derived_from")
    end

    test "the plate numbers its suggestions and the contents column counts them" do
      two_suggestions!
      get project_path(@project)
      assert_response :success

      assert_select "section.plate.tidy-up#tidy-up" do
        assert_select ".plate-count", text: "2 suggestions"
        assert_select "li.plate-cell", 2
        assert_select "li.plate-cell .plate-cell-num", text: "1"
        assert_select "li.plate-cell .plate-cell-num", text: "2"
        assert_select "li.tidy-cell--loose", text: /harbor\.svg sits in the project folder, and design\/harbor\.svg already\s+exists/
        assert_select "li.tidy-cell--loose a.linkbtn[href=?]", file_path(@loose.node_id)
        assert_select "li.tidy-cell--export-older", text: /hex tiles\.svg was made from hex tiles\.lbrn2/
        assert_select "li.tidy-cell--export-older a.linkbtn[href=?]", file_path(@source.node_id), text: "Open the source"
        assert_select "form[action=?] button", project_tidy_dismissals_path(@project), text: "Dismiss", count: 2
      end
      assert_select "aside.column .project-contents a.column-row[href='#tidy-up']" do
        assert_select ".column-row-name", text: "Tidy up"
        assert_select ".column-row-note", text: "2"
      end
    end

    test "a project with nothing to tidy draws no plate and no column row" do
      project_folder_rows!(@user, @project)
      get project_path(@project)
      assert_response :success

      assert_select "#tidy-up", count: 0
      assert_select "aside.column a.column-row[href='#tidy-up']", count: 0
    end

    # The editor draws the edit area's head, never the list, and does not pay for its checks.
    test "the layout editor draws no tidy-up plate" do
      two_suggestions!
      get edit_layout_project_path(@project)
      assert_response :success

      assert_select "#tidy-up", count: 0
    end

    test "Dismiss records the state the server computed and takes the cell off the page" do
      two_suggestions!
      post project_tidy_dismissals_path(@project),
           params: { kind: "export_older", subject: "#{@export.node_id}>#{@source.node_id}", state: "forged" }
      assert_redirected_to project_path(@project, anchor: "tidy-up")
      assert_equal "Dismissed the suggestion.", flash[:notice]

      row = @project.tidy_dismissals.sole
      assert_equal [ "export_older", "2000" ], [ row.kind, row.state ], "the state is the server's, never the form's"

      get project_path(@project)
      assert_select "li.plate-cell", 1
      assert_select "li.tidy-cell--export-older", count: 0
      assert_select ".column-row-note", text: "1"
    end

    test "Dismiss on a suggestion the page no longer raises records nothing" do
      two_suggestions!
      @loose.update!(name: "harbor-v2.svg")
      post project_tidy_dismissals_path(@project), params: { kind: "loose", subject: @loose.node_id }

      assert_redirected_to project_path(@project, anchor: "tidy-up")
      assert_equal "Dismissed nothing: that suggestion no longer applies.", flash[:notice]
      assert_empty @project.tidy_dismissals
    end

    test "Dismiss refuses a kind the list does not have, and another maker's project is not found" do
      two_suggestions!
      post project_tidy_dismissals_path(@project), params: { kind: "sheet", subject: @loose.node_id }
      assert_equal "That is not a suggestion this page makes.", flash[:alert]
      assert_empty @project.tidy_dismissals

      stranger = User.create!(email: "stranger@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = stranger.maker_projects.create!(name: "Theirs")
      post project_tidy_dismissals_path(theirs), params: { kind: "loose", subject: @loose.node_id }
      assert_response :not_found
      assert_empty Maker::TidyDismissal.where(project: theirs)
    end

    # A real working tree, share pinned on every leg: the cell links the commit box.
    test "a repository with changes git has not committed is a cell that links the commit box" do
      root = make_repo!(name: "catan", files: { "notes.md" => "old\n" })
      @project.update_column(:folder_node_id, root.node_id)
      File.write(File.join(library_root, "catan", "notes.md"), "new\n")

      get project_path(@project)
      assert_response :success
      assert_select "li.tidy-cell--uncommitted", text: /This folder's repository has\s+1 changed file that git has not committed/
      assert_select "li.tidy-cell--uncommitted a.linkbtn[href=?]", repo_commit_path(root.node_id), text: "Review"

      post project_tidy_dismissals_path(@project), params: { kind: "uncommitted", subject: root.node_id }
      assert_equal Maker::TidyUp.paths_state([ "notes.md" ]), @project.tidy_dismissals.sole.state
      get project_path(@project)
      assert_select "#tidy-up", count: 0
    end

    test "Home's Needs attention carries the out-of-date row until it is dismissed" do
      two_suggestions!
      get root_path
      assert_response :success
      assert_select ".home-attention li.tidy-attention--export-older" do
        assert_select ".attention-kind", text: "Out of date"
        assert_select ".attention-text", text: "Catan: hex tiles.svg is older than hex tiles.lbrn2."
        assert_select "a.linkbtn[href=?]", project_path(@project, anchor: "tidy-up"), text: "Open"
      end

      post project_tidy_dismissals_path(@project), params: { kind: "export_older", subject: "#{@export.node_id}>#{@source.node_id}" }
      get root_path
      assert_select ".tidy-attention", count: 0
    end
  end
end
