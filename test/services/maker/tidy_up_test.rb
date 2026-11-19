require "test_helper"
require "support/git_repo_fixture"

# THE TIDY-UP LIST'S THREE CHECKS (the Shop manual's §9, 2026-11-19; Maker::TidyUp), each with the
# case that must raise it and the cases that must not, and the dismissal rule: a dismissed suggestion
# stays gone while its state is unchanged and comes back the moment the thing it is about changes.
#
# PORT-FREE WHERE IT CAN BE: the loose and export checks read catalog rows only
# (`project_folder_rows!`), so they run the same on every backend leg. The git check needs a real
# working tree, so those cases pin a share library through GitRepoFixture#library_root, which is what
# keeps all three legs running every test here (§15: RUN counts must match) — and the one case about
# a backend WITHOUT a local working tree hands the service such capabilities rather than depending on
# the leg.
class Maker::TidyUpTest < ActiveSupport::TestCase
  include GitRepoFixture

  LOCAL = FileLayer::Capabilities.new(versioned: false, syncable: false, presignable: false, scannable: true,
                                      port_writable: true, local_worktree: true)
  REMOTE = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false, scannable: false,
                                       port_writable: false, local_worktree: false)

  setup do
    @user = User.create!(email: "tidy-#{SecureRandom.hex(4)}@example.com")
    @project = @user.maker_projects.create!(name: "Catan")
  end

  def tidy(project = @project, capabilities: REMOTE, repos: nil)
    listing = Maker::ProjectFolderListing.new(@user, project)
    repos ||= Maker::TidyUp.repos_in(@user, listing, project, capabilities:)
    Maker::TidyUp.for(user: @user, project:, listing:, repos:, capabilities:)
  end

  def dir!(name, parent)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent.node_id, mtime: 1, size: 0)
  end

  def file!(name, parent, mtime: 1_700_000_000_000_000_000, id: SecureRandom.uuid)
    @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent&.node_id, size: 1, mtime:,
                        content_hash: "h-#{id}", current_version_id: "v-#{id}")
  end

  # --- loose files --------------------------------------------------------------------------

  # The UX audit's own case: the svg rule names `design`, which already holds the name.
  test "a loose file whose folder already holds its name is a suggestion" do
    folder = project_folder_rows!(@user, @project)
    file!("harbor.svg", dir!("design", folder))
    loose = file!("harbor.svg", folder)

    suggestion = tidy.suggestions.sole
    assert_equal [ "loose", loose.node_id, "design/harbor.svg" ], [ suggestion.kind, suggestion.subject, suggestion.state ]
    assert_equal "design", suggestion.detail.dir.name
  end

  test "a loose file the next pass will file is not a suggestion" do
    folder = project_folder_rows!(@user, @project)
    file!("other.svg", dir!("design", folder))
    file!("harbor.svg", folder)

    assert_empty tidy.all
  end

  test "an autofile-off project suggests no loose file" do
    folder = project_folder_rows!(@user, @project)
    file!("harbor.svg", dir!("design", folder))
    file!("harbor.svg", folder)
    @project.update!(autofile: false)

    assert_empty tidy.all
  end

  test "a README at the root is never a loose-file suggestion" do
    folder = project_folder_rows!(@user, @project)
    file!("README.md", dir!("docs", folder))
    file!("README.md", folder)

    assert_empty tidy.all
  end

  # Maker::AttachToProject#refusal_for answers :in_working_tree before the collision is reached.
  test "a folder inside a working tree suggests no loose file" do
    folder = project_folder_rows!(@user, @project)
    dir!(Library::RepoMetadata::DIR_NAME, @user.nodes.find_by!(node_id: folder.parent_node_id))
    file!("harbor.svg", dir!("design", folder))
    file!("harbor.svg", folder)

    assert_empty tidy.all
  end

  test "a file in a model's bundle suggests no loose file" do
    folder = project_folder_rows!(@user, @project)
    file!("harbor.svg", dir!("design", folder))
    loose = file!("harbor.svg", folder)
    model = @user.maker_models.create!(title: "Harbor", slug: "harbor")
    model.file_attachments.create!(user: @user, node_id: loose.node_id, role: "vector")

    assert_empty tidy.all
  end

  # --- exports older than their source --------------------------------------------------------

  test "an export older than its source is a suggestion, with the source's mtime as its state" do
    folder = project_folder_rows!(@user, @project)
    source = file!("hex tiles.lbrn2", dir!("laser", folder), mtime: 2_000)
    export = file!("hex tiles.svg", dir!("design", folder), mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: export.node_id, to_node_id: source.node_id, kind: "derived_from")

    suggestion = tidy.suggestions.sole
    assert_equal [ "export_older", "#{export.node_id}>#{source.node_id}", "2000" ],
                 [ suggestion.kind, suggestion.subject, suggestion.state ]
    assert_equal [ "hex tiles.svg", "hex tiles.lbrn2" ], [ suggestion.detail.derived_name, suggestion.detail.source_name ]
  end

  test "an export newer than its source, or with no mtime, is not a suggestion" do
    folder = project_folder_rows!(@user, @project)
    laser = dir!("laser", folder)
    fresh_source = file!("a.lbrn2", laser, mtime: 1_000)
    fresh_export = file!("a.svg", folder, mtime: 2_000)
    blank_source = file!("b.lbrn2", laser, mtime: nil)
    blank_export = file!("b.svg", folder, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: fresh_export.node_id, to_node_id: fresh_source.node_id, kind: "derived_from")
    @user.maker_file_links.create!(from_node_id: blank_export.node_id, to_node_id: blank_source.node_id, kind: "derived_from")

    assert_empty tidy.all
  end

  test "an export whose source is in the trash is not a suggestion" do
    folder = project_folder_rows!(@user, @project)
    source = file!("a.lbrn2", folder, mtime: 2_000)
    export = file!("a.svg", folder, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: export.node_id, to_node_id: source.node_id, kind: "derived_from")
    source.update!(deleted: true)

    assert_empty tidy.all
  end

  # A photograph older than the file it shows is a photo, not an export.
  test "a photo older than the file it depicts is not a suggestion" do
    folder = project_folder_rows!(@user, @project)
    depicted = file!("lamp.stl", folder, mtime: 2_000)
    photo = file!("lamp.jpg", folder, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: photo.node_id, to_node_id: depicted.node_id, kind: "photo_of")

    assert_empty tidy.all
  end

  # Either end inside the folder makes it this project's; neither, and it is no project's.
  test "an export counts when either end is in the folder, and not when neither is" do
    folder = project_folder_rows!(@user, @project)
    elsewhere = @user.nodes.create!(node_id: SecureRandom.uuid, name: "Elsewhere", kind: "dir", mtime: 1, size: 0)
    source = file!("a.lbrn2", elsewhere, mtime: 2_000)
    export = file!("a.svg", dir!("design", folder), mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: export.node_id, to_node_id: source.node_id, kind: "derived_from")
    stray_source = file!("b.lbrn2", elsewhere, mtime: 2_000)
    stray_export = file!("b.svg", elsewhere, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: stray_export.node_id, to_node_id: stray_source.node_id, kind: "derived_from")

    assert_equal [ export.node_id ], tidy.suggestions.map { |s| s.detail.derived_id }
  end

  # --- uncommitted changes (a real working tree, share pinned on every leg) --------------------

  test "a repository with a changed file is a suggestion, counted without OS clutter" do
    root = make_repo!(name: "catan", files: { "notes.md" => "old\n", "board.svg" => "<svg/>\n" })
    @project.update_column(:folder_node_id, root.node_id)
    File.write(File.join(library_root, "catan", "notes.md"), "new\n")
    File.write(File.join(library_root, "catan", ".DS_Store"), "junk")

    suggestion = tidy(capabilities: LOCAL).suggestions.sole
    assert_equal [ "uncommitted", root.node_id, 1, true ],
                 [ suggestion.kind, suggestion.subject, suggestion.detail.count, suggestion.detail.root ]
    assert_equal Maker::TidyUp.paths_state([ "notes.md" ]), suggestion.state
  end

  test "a clean repository, or one changed only by OS clutter, is not a suggestion" do
    root = make_repo!(name: "catan")
    @project.update_column(:folder_node_id, root.node_id)
    assert_empty tidy(capabilities: LOCAL).all

    File.write(File.join(library_root, "catan", ".DS_Store"), "junk")
    assert_empty tidy(capabilities: LOCAL).all
  end

  # A nested working tree is asked about too, under its own name.
  test "a repository inside the project folder is a suggestion under its own name" do
    bench = File.join(library_root, "bench")
    FileUtils.mkdir_p(File.join(bench, "firmware"))
    repo = Rugged::Repository.init_at(File.join(bench, "firmware"))
    File.write(File.join(bench, "firmware", "main.c"), "int main;\n")
    Library::ScanJob.new.perform(user_id: @user.id)
    @project.update_column(:folder_node_id, @user.nodes.present.find_by!(name: "bench", kind: "dir").node_id)
    assert repo.head_unborn?

    suggestion = tidy(capabilities: LOCAL).suggestions.sole
    assert_equal [ "firmware", false, 1 ], [ suggestion.detail.name, suggestion.detail.root, suggestion.detail.count ]
  end

  # Where the library is not a local folder, git is never asked, whatever the repository holds.
  test "no backend without a local working tree is asked about uncommitted changes" do
    root = make_repo!(name: "catan")
    @project.update_column(:folder_node_id, root.node_id)
    File.write(File.join(library_root, "catan", "notes.md"), "new\n")

    # Each gate on its own: the checks given the repository anyway, and the lookup that finds it.
    listing = Maker::ProjectFolderListing.new(@user, @project)
    repos = Maker::TidyUp.repos_in(@user, listing, @project, capabilities: LOCAL)
    assert_equal [ root.node_id ], repos.map { |r| r.node.node_id }
    assert_empty Maker::TidyUp.for(user: @user, project: @project, listing:, repos:, capabilities: REMOTE).all
    assert_empty Maker::TidyUp.repos_in(@user, listing, @project, capabilities: REMOTE)
  end

  # --- dismissals ----------------------------------------------------------------------------

  def dismiss!(suggestion, project: @project)
    Maker::TidyDismissal.record!(user: @user, project:, kind: suggestion.kind, subject: suggestion.subject,
                                 state: suggestion.state)
  end

  test "a dismissed loose file stays gone until the path that blocks it changes" do
    folder = project_folder_rows!(@user, @project)
    file!("harbor.svg", dir!("design", folder))
    file!("harbor.svg", dir!("drawings", folder))
    file!("harbor.svg", folder)
    dismiss!(tidy.suggestions.sole)

    assert_empty tidy.suggestions, "a dismissed suggestion must leave the list"
    assert_equal 1, tidy.all.size, "a dismissed suggestion is still found by the dismissal door"

    # The maker points svg at `drawings`, which holds the name too: a new reason, so it comes back.
    Maker::FilingRules.for(@user)
    @user.maker_filing_rules.find_by!(ext: "svg").update!(folder: "drawings")
    assert_equal "drawings/harbor.svg", tidy.suggestions.sole.state
  end

  test "a dismissed export comes back when its source is edited again" do
    folder = project_folder_rows!(@user, @project)
    source = file!("a.lbrn2", folder, mtime: 2_000)
    export = file!("a.svg", folder, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: export.node_id, to_node_id: source.node_id, kind: "derived_from")
    dismiss!(tidy.suggestions.sole)
    assert_empty tidy.suggestions

    source.update!(mtime: 3_000)
    assert_equal "3000", tidy.suggestions.sole.state
  end

  test "a dismissal on one project does not hide the suggestion on another" do
    folder = project_folder_rows!(@user, @project)
    source = file!("a.lbrn2", folder, mtime: 2_000)
    export = file!("a.svg", folder, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: export.node_id, to_node_id: source.node_id, kind: "derived_from")
    other = @user.maker_projects.create!(name: "Other")
    dismiss!(tidy.suggestions.sole, project: other)

    assert_equal 1, tidy.suggestions.size
  end

  test "a dismissed repository comes back when another path changes, or the app saves into it" do
    root = make_repo!(name: "catan", files: { "notes.md" => "old\n", "board.svg" => "<svg/>\n" })
    @project.update_column(:folder_node_id, root.node_id)
    File.write(File.join(library_root, "catan", "notes.md"), "new\n")
    travel_to(2.days.ago) { dismiss!(tidy(capabilities: LOCAL).suggestions.sole) }
    assert_empty tidy(capabilities: LOCAL).suggestions, "a dismissed repository must leave the list"

    # The app saves into an already-changed file: the path set is the same, the save is new.
    notes = @user.nodes.present.find_by!(name: "notes.md")
    travel_to(1.day.ago) { Maker::RepoEdit.record!(user: @user, repo_root_node_id: root.node_id, node_id: notes.node_id) }
    assert_equal 1, tidy(capabilities: LOCAL).suggestions.size, "a save after the dismissal must bring it back"

    dismiss!(tidy(capabilities: LOCAL).suggestions.sole)
    assert_empty tidy(capabilities: LOCAL).suggestions

    File.write(File.join(library_root, "catan", "board.svg"), "<svg></svg>\n")
    assert_equal 2, tidy(capabilities: LOCAL).suggestions.sole.detail.count, "a new changed path must bring it back"
  end

  test "a dismissal is recorded once per suggestion, its state and time replaced" do
    folder = project_folder_rows!(@user, @project)
    file!("harbor.svg", dir!("design", folder))
    loose = file!("harbor.svg", folder)
    first = travel_to(1.day.ago) { Maker::TidyDismissal.record!(user: @user, project: @project, kind: "loose", subject: loose.node_id, state: "a") }
    again = Maker::TidyDismissal.record!(user: @user, project: @project, kind: "loose", subject: loose.node_id, state: "a")

    assert_equal first.id, again.id
    assert_operator again.reload.updated_at, :>, 1.hour.ago, "re-dismissing must move the time"
    assert_equal 1, @project.tidy_dismissals.count
  end
end
