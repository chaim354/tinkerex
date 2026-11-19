require "test_helper"

# HOME'S TIDY-UP ROWS (the Shop manual's §9, 2026-11-19; Maker::TidyUp::Attention): OUT OF DATE from
# the project page's own check, NOT COMMITTED from the app's own pending saves (Home runs no git),
# each attributed to the project whose folder holds it, and each gone while the maker's dismissal on
# that project's page still holds. Catalog rows only, so every case runs the same on every leg; the
# capabilities are handed in, never read off the leg.
class Maker::TidyUpAttentionTest < ActiveSupport::TestCase
  LOCAL = FileLayer::Capabilities.new(versioned: false, syncable: false, presignable: false, scannable: true,
                                      port_writable: true, local_worktree: true)
  REMOTE = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false, scannable: false,
                                       port_writable: false, local_worktree: false)

  setup do
    @user = User.create!(email: "attention-#{SecureRandom.hex(4)}@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
    @folder = project_folder_rows!(@user, @project)
  end

  def rows(capabilities: LOCAL) = Maker::TidyUp::Attention.for(@user, limit: 5, capabilities:)

  def file!(name, parent, mtime: 1_000)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent.node_id, size: 1, mtime:)
  end

  def stale_pair!(parent = @folder)
    source = file!("board.kicad_pcb", parent, mtime: 2_000)
    export = file!("board.gbr", parent, mtime: 1_000)
    @user.maker_file_links.create!(from_node_id: export.node_id, to_node_id: source.node_id, kind: "derived_from")
    [ export, source ]
  end

  def repo!(name = "firmware")
    dir = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: @folder.node_id, mtime: 1, size: 0)
    @user.nodes.create!(node_id: SecureRandom.uuid, name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                        parent_node_id: dir.node_id, mtime: 1, size: 0)
    dir
  end

  test "an export older than its source is a row under the project that holds it" do
    export, = stale_pair!(@user.nodes.create!(node_id: SecureRandom.uuid, name: "pcb", kind: "dir",
                                             parent_node_id: @folder.node_id, mtime: 1, size: 0))

    row = rows.sole
    assert_equal [ "export_older", @project.id, export.node_id ], [ row.kind, row.project.id, row.detail.derived_id ]
  end

  test "a dismissed export leaves Home and comes back when its source changes" do
    export, source = stale_pair!
    Maker::TidyDismissal.record!(user: @user, project: @project, kind: "export_older",
                                 subject: "#{export.node_id}>#{source.node_id}", state: "2000")
    assert_empty rows

    source.update!(mtime: 5_000)
    assert_equal 1, rows.size
  end

  test "an export in no project, or in an archived one, is not a row" do
    loose_dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "Loose", kind: "dir", mtime: 1, size: 0)
    stale_pair!(loose_dir)
    archived = @user.maker_projects.create!(name: "Old", status: "archived")
    stale_pair!(project_folder_rows!(@user, archived))

    assert_empty rows
  end

  test "files saved into a repository and not committed are a row, counted from live saves" do
    repo = repo!
    saved = 2.times.map { file!("main#{_1}.c", repo) }
    saved.each { Maker::RepoEdit.record!(user: @user, repo_root_node_id: repo.node_id, node_id: _1.node_id) }
    gone = file!("gone.c", repo)
    Maker::RepoEdit.record!(user: @user, repo_root_node_id: repo.node_id, node_id: gone.node_id)
    gone.update!(deleted: true)

    row = rows.sole
    assert_equal [ "uncommitted", @project.id, repo.node_id, "firmware", 2 ],
                 [ row.kind, row.project.id, row.detail.root_node_id, row.detail.name, row.detail.count ]
  end

  # Elsewhere the app records no pending save and there is no commit box, so Home asks nothing.
  test "no row is about uncommitted saves where the library is not a local folder" do
    repo = repo!
    Maker::RepoEdit.record!(user: @user, repo_root_node_id: repo.node_id, node_id: file!("a.c", repo).node_id)

    assert_empty rows(capabilities: REMOTE)
  end

  # Home has no git digest, so its rule is time: a dismissal holds while it is newer than every save.
  test "a dismissed repository leaves Home until the app saves into it again" do
    repo = repo!
    main = file!("main.c", repo)
    travel_to(2.days.ago) { Maker::RepoEdit.record!(user: @user, repo_root_node_id: repo.node_id, node_id: main.node_id) }
    travel_to(1.day.ago) do
      Maker::TidyDismissal.record!(user: @user, project: @project, kind: "uncommitted", subject: repo.node_id, state: "digest")
    end
    assert_empty rows

    Maker::RepoEdit.record!(user: @user, repo_root_node_id: repo.node_id, node_id: main.node_id)
    assert_equal 1, rows.size
  end

  test "the rows are bounded by the limit" do
    6.times { stale_pair! }

    assert_equal 5, rows.size
  end
end
