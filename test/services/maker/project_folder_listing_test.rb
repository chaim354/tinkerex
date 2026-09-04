require "test_helper"

module Maker
  # BACKEND-NEUTRAL FIXTURES, same argument as library_tree_test.rb's: this class reads `nodes`
  # and `maker_projects` and never touches the port (no mkdir, no move, no bytes), so a bare
  # `create!` is a complete fixture -- there is no storage_path for a reader to trip over.
  class ProjectFolderListingTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pfl-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def project_with_folder(folder_node_id, name: "Desk Lamp")
      @user.maker_projects.create!(name:, folder_node_id:)
    end

    # The standard Projects/desk-lamp chain -- a real ancestor pair, not a bare root dir, so
    # `listing.path` exercises the same slash-joined walk a live deployment would.
    def desk_lamp_folder
      projects = dir("dir-projects", "Projects", nil)
      desk_lamp = dir("dir-desk-lamp", "desk-lamp", projects.node_id)
      [ projects, desk_lamp ]
    end

    # The house mutation-check helper (project_scan_button_test.rb carries the same body; there is
    # no shared copy in test_helper.rb, so each suite that needs it defines its own).
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end

    test "files at the folder root and in subfolders are listed; a library-root file is not" do
      _projects, desk_lamp = desk_lamp_folder
      docs = dir("dir-docs", "docs", desk_lamp.node_id)
      models = dir("dir-models", "models", desk_lamp.node_id)
      file("f-root", "bracket.stl", desk_lamp.node_id)
      file("f-docs", "manual.pdf", docs.node_id)
      file("f-models", "shade.stl", models.node_id)
      file("f-outside", "orphan.stl", nil) # sits at the library root, not inside the folder

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert listing.available?
      assert_equal "Projects/desk-lamp", listing.path
      assert_equal %w[bracket.stl manual.pdf shade.stl], listing.files.map { |r| r.node.name }.sort
      assert_equal 3, listing.total
      assert_not listing.truncated?, "an ordinary small listing must not read as truncated"
    end

    test "a dot-dir's contents are skipped, and a bare .git marker is never its own repo" do
      _projects, desk_lamp = desk_lamp_folder
      stversions = dir("dir-stversions", ".stversions", desk_lamp.node_id)
      file("f-hidden", "x.stl", stversions.node_id)
      dir("dir-git", ".git", desk_lamp.node_id)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal [], listing.files
      assert_equal 0, listing.total
      assert_equal [], listing.repos
    end

    test "a subdir holding a .git child is one Repo, its files are excluded, and the root's own files still list even when the root itself looks like a working tree" do
      _projects, desk_lamp = desk_lamp_folder
      file("f-root", "bracket.stl", desk_lamp.node_id)
      dir("dir-root-git", ".git", desk_lamp.node_id) # desk-lamp ITSELF has a .git child
      firmware = dir("dir-firmware", "firmware", desk_lamp.node_id)
      dir("dir-firmware-git", ".git", firmware.node_id)
      file("f-firmware", "main.c", firmware.node_id)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal 1, listing.repos.size
      repo = listing.repos.first
      assert_equal firmware.node_id, repo.node_id
      assert_equal "firmware", repo.name
      assert_equal "Projects/desk-lamp/firmware", repo.path

      # The root is always entered regardless of its own .git child -- only a CHILD's working-tree
      # status diverts it into @repos; the walk never asks the question about root_id itself.
      assert_equal [ "bracket.stl" ], listing.files.map { |r| r.node.name }
    end

    test "a tombstoned subfolder's files are absent -- the tree holds live dirs only" do
      _projects, desk_lamp = desk_lamp_folder
      archive = dir("dir-archive", "archive", desk_lamp.node_id)
      file("f-archived", "old.stl", archive.node_id)
      archive.update!(deleted: true)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal [], listing.files
      assert_equal 0, listing.total
    end

    test "more than FILE_CAP files truncates the tile list but not the total" do
      _projects, desk_lamp = desk_lamp_folder
      now = Time.current
      Node.insert_all((Maker::ProjectFolderListing::FILE_CAP + 1).times.map do |i|
        { node_id: "bulk-#{i}", name: format("f%03d.stl", i), kind: "file", user_id: @user.id,
          parent_node_id: desk_lamp.node_id, size: 1, mtime: 1, deleted: false,
          created_at: now, updated_at: now }
      end)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal Maker::ProjectFolderListing::FILE_CAP, listing.files.size
      assert listing.truncated?
      assert_equal Maker::ProjectFolderListing::FILE_CAP + 1, listing.total
    end

    # THE DIR HALF OF TRUNCATED?, easy to miss because FILE_CAP's own check (fetch N+1, compare
    # sizes) has nothing to do with it: a folder can blow DIR_CAP with a handful of files spread
    # across many subfolders and never come near FILE_CAP.
    test "more than DIR_CAP dirs also reads as truncated" do
      _projects, desk_lamp = desk_lamp_folder
      now = Time.current
      Node.insert_all((Maker::ProjectFolderListing::DIR_CAP + 1).times.map do |i|
        { node_id: "bulkdir-#{i}", name: format("d%03d", i), kind: "dir", user_id: @user.id,
          parent_node_id: desk_lamp.node_id, size: 0, mtime: 1, deleted: false,
          created_at: now, updated_at: now }
      end)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert listing.truncated?
    end

    test "no folder_node_id, or one naming a tombstoned dir, lists nothing and mints nothing" do
      dead = dir("dir-dead", "Dead", nil)
      dead.update!(deleted: true)
      no_folder = project_with_folder(nil, name: "No Folder")
      dead_folder = project_with_folder(dead.node_id, name: "Dead Folder")

      before = @user.nodes.count
      replacing(Maker::LibraryFolder, :ensure_path!,
                ->(*) { raise "ProjectFolderListing must never call ensure_path! -- it is a reader" }) do
        listing = Maker::ProjectFolderListing.new(@user, no_folder)
        assert_not listing.available?
        assert_equal [], listing.files
        assert_equal 0, listing.total

        listing2 = Maker::ProjectFolderListing.new(@user, dead_folder)
        assert_not listing2.available?
        assert_equal [], listing2.files
        assert_equal 0, listing2.total
      end
      assert_equal before, @user.nodes.count
    end

    test "load_files: false skips the files query; total and repos are still right, in exactly two queries" do
      _projects, desk_lamp = desk_lamp_folder
      firmware = dir("dir-firmware", "firmware", desk_lamp.node_id)
      dir("dir-firmware-git", ".git", firmware.node_id)
      file("f-root", "bracket.stl", desk_lamp.node_id)

      project = project_with_folder(desk_lamp.node_id)
      listing = nil
      n = count_queries { listing = Maker::ProjectFolderListing.new(@user, project, load_files: false) }

      assert_equal [], listing.files
      assert_equal 1, listing.total
      assert_equal 1, listing.repos.size
      assert_equal "firmware", listing.repos.first.name
      assert_equal 2, n, "expected exactly the dirs pluck and the count -- got #{n}"
    end

    test "Row#role reads the filename and Row#backup? recognizes a LightBurn rescue copy" do
      node = @user.nodes.create!(node_id: "f-role", name: "plate.dxf", kind: "file",
                                 parent_node_id: nil, mtime: 1, size: 1)
      row = Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: false)
      assert_equal "vector", row.role
      assert_not row.backup?

      backup_node = @user.nodes.create!(node_id: "f-backup", name: "plate_backup.lbrn2", kind: "file",
                                        parent_node_id: nil, mtime: 1, size: 1)
      backup_row = Maker::ProjectFolderListing::Row.new(node: backup_node, attachment: nil, linked: false)
      assert backup_row.backup?
    end
    test "contains? is the folder's ancestry, not the capped list" do
      _projects, desk_lamp = desk_lamp_folder
      deep = dir("dir-deep", "docs", desk_lamp.node_id)
      firmware = dir("dir-firmware", "firmware", desk_lamp.node_id)
      dir("dir-firmware-git", ".git", firmware.node_id)
      src = dir("dir-firmware-src", "src", firmware.node_id)
      inside_deep = file("f-deep", "manual.pdf", deep.node_id)
      inside_repo = file("f-repo", "main.c", src.node_id)
      outside = file("f-outside", "orphan.stl", nil)
      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      assert listing.contains?(inside_deep)
      assert listing.contains?(inside_repo), "a file inside a repository the walk never entered is still IN the folder"
      assert_not listing.node_ids.include?(inside_repo.node_id), "…and yet is not listed (the repo entry stands for it)"
      assert_not listing.contains?(outside)
      assert_not Maker::ProjectFolderListing.new(@user, project_with_folder(nil, name: "Bare")).contains?(inside_deep),
                 "no folder contains nothing"
    end
  end
end
