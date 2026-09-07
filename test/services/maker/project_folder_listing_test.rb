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

    # Flattens every file Row out of a tree, depth-first, for assertions that don't care which
    # level a file sits at.
    def all_tree_files(dirs)
      dirs.flat_map { |d| d.files + all_tree_files(d.children) }
    end

    def names_of(rows) = rows.map { |r| r.node.name }

    test "files at the folder root are loose; a subfolder's files sit under its own Dir; a library-root file is absent entirely" do
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
      assert_equal %w[bracket.stl], names_of(listing.loose)
      assert_equal %w[docs models], listing.tree.map(&:name).sort
      assert_equal %w[manual.pdf], names_of(listing.tree.find { |d| d.name == "docs" }.files)
      assert_equal %w[shade.stl], names_of(listing.tree.find { |d| d.name == "models" }.files)
      assert_equal 3, listing.total
      assert_not listing.truncated?, "an ordinary small listing must not read as truncated"
    end

    test "a nested subfolder appears under its parent's own Dir, each carrying its own files" do
      _projects, desk_lamp = desk_lamp_folder
      docs = dir("dir-docs", "docs", desk_lamp.node_id)
      wiring = dir("dir-wiring", "wiring", docs.node_id)
      file("f-manual", "manual.pdf", docs.node_id)
      file("f-pinout", "pinout.pdf", wiring.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      docs_dir = listing.tree.sole
      assert_equal "docs", docs_dir.name
      assert_equal "Projects/desk-lamp/docs", docs_dir.path
      assert_equal %w[manual.pdf], names_of(docs_dir.files)
      wiring_dir = docs_dir.children.sole
      assert_equal "wiring", wiring_dir.name
      assert_equal %w[pinout.pdf], names_of(wiring_dir.files)
    end

    # AN EMPTY SUBFOLDER IS STILL LISTED -- it is real, on disk, and hiding it would say less than
    # the folder actually holds. Its own children (none here) render as an empty <details> too.
    test "an empty subfolder appears in the tree with no files and no children" do
      _projects, desk_lamp = desk_lamp_folder
      dir("dir-empty", "empty", desk_lamp.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      empty_dir = listing.tree.sole
      assert_equal "empty", empty_dir.name
      assert_equal [], empty_dir.files
      assert_equal [], empty_dir.children
    end

    test "dirs sort by name and each dir's own files sort by name" do
      _projects, desk_lamp = desk_lamp_folder
      dir("dir-zebra", "zebra", desk_lamp.node_id)
      alpha = dir("dir-alpha", "alpha", desk_lamp.node_id)
      file("f-2", "b.stl", alpha.node_id)
      file("f-1", "a.stl", alpha.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      assert_equal %w[alpha zebra], listing.tree.map(&:name)
      assert_equal %w[a.stl b.stl], names_of(listing.tree.first.files)
    end

    test "a dot-dir's contents are skipped, and a bare .git marker is never its own repo" do
      _projects, desk_lamp = desk_lamp_folder
      stversions = dir("dir-stversions", ".stversions", desk_lamp.node_id)
      file("f-hidden", "x.stl", stversions.node_id)
      dir("dir-git", ".git", desk_lamp.node_id)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal [], listing.loose
      assert_equal [], listing.tree
      assert_equal 0, listing.total
      assert_equal [], listing.repos
    end

    test "a subdir holding a .git child is entered as a repo section, its files listed under it, and the root's own files still list even when the root itself looks like a working tree" do
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

      firmware_dir = listing.tree.find { |d| d.name == "firmware" }
      assert firmware_dir.repo?
      assert_equal %w[main.c], names_of(firmware_dir.files)

      # The root is always entered regardless of its own .git child -- only a CHILD's working-tree
      # status flags it as a repo; the walk never asks the question about root_id itself.
      assert_equal %w[bracket.stl], names_of(listing.loose)
    end

    # STAGE 3, S3-1: a working tree is ENTERED, not stopped at -- its own subfolders nest exactly
    # like any other folder's.
    test "a repo's own subfolder nests inside it, and only the .git marker's contents are unobserved" do
      _projects, desk_lamp = desk_lamp_folder
      firmware = dir("dir-firmware", "firmware", desk_lamp.node_id)
      dir("dir-firmware-git", ".git", firmware.node_id)
      src = dir("dir-src", "src", firmware.node_id)
      file("f-main", "main.c", src.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      firmware_dir = listing.tree.sole
      assert firmware_dir.repo?
      src_dir = firmware_dir.children.sole
      assert_equal "src", src_dir.name
      assert_equal %w[main.c], names_of(src_dir.files)
    end

    test "a tombstoned subfolder's files are absent -- the tree holds live dirs only" do
      _projects, desk_lamp = desk_lamp_folder
      archive = dir("dir-archive", "archive", desk_lamp.node_id)
      file("f-archived", "old.stl", archive.node_id)
      archive.update!(deleted: true)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal [], listing.tree
      assert_equal [], listing.loose
      assert_equal 0, listing.total
    end

    test "more than FILE_CAP files truncates the listing but not the total" do
      _projects, desk_lamp = desk_lamp_folder
      now = Time.current
      Node.insert_all((Maker::ProjectFolderListing::FILE_CAP + 1).times.map do |i|
        { node_id: "bulk-#{i}", name: format("f%03d.stl", i), kind: "file", user_id: @user.id,
          parent_node_id: desk_lamp.node_id, size: 1, mtime: 1, deleted: false,
          created_at: now, updated_at: now }
      end)

      project = project_with_folder(desk_lamp.node_id)
      listing = Maker::ProjectFolderListing.new(@user, project)

      assert_equal Maker::ProjectFolderListing::FILE_CAP, listing.loose.size
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
        assert_equal [], listing.tree
        assert_equal [], listing.loose
        assert_equal 0, listing.total

        listing2 = Maker::ProjectFolderListing.new(@user, dead_folder)
        assert_not listing2.available?
        assert_equal [], listing2.tree
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

      assert_equal [], listing.loose
      assert_equal 1, listing.total
      assert_equal 1, listing.repos.size
      assert_equal "firmware", listing.repos.first.name
      assert_equal 2, n, "expected exactly the dirs pluck and the count -- got #{n}"
    end

    test "Row#role reads the filename and Row#backup? recognizes a LightBurn rescue copy" do
      node = @user.nodes.create!(node_id: "f-role", name: "plate.dxf", kind: "file",
                                 parent_node_id: nil, mtime: 1, size: 1)
      row = Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: false, section: "")
      assert_equal "vector", row.role
      assert_not row.backup?

      backup_node = @user.nodes.create!(node_id: "f-backup", name: "plate_backup.lbrn2", kind: "file",
                                        parent_node_id: nil, mtime: 1, size: 1)
      backup_row = Maker::ProjectFolderListing::Row.new(node: backup_node, attachment: nil, linked: false, section: "")
      assert backup_row.backup?
    end

    # BACKUPS ARE PULLED OUT OF THE TREE (stage 3, S3-1), wherever they physically sit, into one
    # flat cross-cutting list -- each still carrying the SECTION it was pulled from, so the panel's
    # list view can say where a rescue copy really lives.
    test "a backup-flagged file is pulled out of its dir into #backups, carrying its own section, and does not appear in the dir's files" do
      _projects, desk_lamp = desk_lamp_folder
      laser = dir("dir-laser", "laser", desk_lamp.node_id)
      file("f-sign", "sign.lbrn2", laser.node_id)
      file("f-bak", "sign_backup.lbrn2", laser.node_id)
      file("f-root-bak", "root_backup.lbrn2", desk_lamp.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      laser_dir = listing.tree.sole
      assert_equal %w[sign.lbrn2], names_of(laser_dir.files)
      assert_equal %w[root_backup.lbrn2 sign_backup.lbrn2], names_of(listing.backups).sort
      backup_row = listing.backups.find { |r| r.node.name == "sign_backup.lbrn2" }
      assert_equal "laser", backup_row.section
      root_backup_row = listing.backups.find { |r| r.node.name == "root_backup.lbrn2" }
      assert_equal "", root_backup_row.section
      # Still counted in the total and in node_ids -- it is a real file in the folder, just not
      # rendered inside its own dir section.
      assert_equal 3, listing.total
      assert_includes listing.node_ids, "f-bak"
    end

    test "Row#section is the display path relative to the project folder, blank for a loose row" do
      _projects, desk_lamp = desk_lamp_folder
      docs = dir("dir-docs", "docs", desk_lamp.node_id)
      wiring = dir("dir-wiring", "wiring", docs.node_id)
      file("f-root", "bracket.stl", desk_lamp.node_id)
      file("f-manual", "manual.pdf", docs.node_id)
      file("f-pinout", "pinout.pdf", wiring.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      assert_equal "", listing.loose.first.section
      docs_dir = listing.tree.sole
      assert_equal "docs", docs_dir.files.first.section
      assert_equal "docs/wiring", docs_dir.children.sole.files.first.section
    end

    test "#path_for answers a node's full library path from the same tree, for a node outside this folder" do
      _projects, desk_lamp = desk_lamp_folder
      elsewhere = dir("dir-elsewhere", "Elsewhere", nil)
      outside = file("f-outside", "orphan.stl", elsewhere.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      assert_equal "Elsewhere", listing.path_for(outside)
    end

    test "#row_for finds this listing's own Row by node_id, and answers nil outside it" do
      _projects, desk_lamp = desk_lamp_folder
      docs = dir("dir-docs", "docs", desk_lamp.node_id)
      file("f-manual", "manual.pdf", docs.node_id)
      outside = file("f-outside", "orphan.stl", nil)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      assert_equal "manual.pdf", listing.row_for("f-manual").node.name
      assert_nil listing.row_for(outside.node_id)
      assert_nil listing.row_for("does-not-exist")
    end

    test "#all_rows holds every row anywhere -- loose, backups, and every depth of the tree" do
      _projects, desk_lamp = desk_lamp_folder
      docs = dir("dir-docs", "docs", desk_lamp.node_id)
      file("f-root", "bracket.stl", desk_lamp.node_id)
      file("f-manual", "manual.pdf", docs.node_id)
      file("f-bak", "manual_backup.pdf", docs.node_id) # not a recognized backup ext -- stays put
      file("f-real-bak", "sign_backup.lbrn2", docs.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))

      assert_equal %w[bracket.stl manual.pdf manual_backup.pdf sign_backup.lbrn2],
                   names_of(listing.all_rows).sort
      assert_equal listing.all_rows.map(&:node_id).sort, listing.node_ids.sort
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
      assert listing.contains?(inside_repo), "a file inside a repository is still IN the folder"
      assert_not listing.contains?(outside)
      assert_not Maker::ProjectFolderListing.new(@user, project_with_folder(nil, name: "Bare")).contains?(inside_deep),
                 "no folder contains nothing"
    end

    test "root_repo? is true when the folder itself holds a .git marker, and false for a repo nested inside" do
      project = @user.maker_projects.create!(name: "Root Repo")
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "root-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: folder.node_id, size: 0, mtime: 1_700_000_000_000_000_000)

      assert Maker::ProjectFolderListing.new(@user, project).root_repo?

      other = @user.maker_projects.create!(name: "Nested Repo")
      other_folder = project_folder_rows!(@user, other)
      firmware = @user.nodes.create!(node_id: "fw-dir", name: "firmware", kind: "dir",
                                     parent_node_id: other_folder.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "fw-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: firmware.node_id, size: 0, mtime: 1_700_000_000_000_000_000)

      listing = Maker::ProjectFolderListing.new(@user, other)
      refute listing.root_repo?, "a repository INSIDE the folder is not the root"
      assert listing.tree.first.repo?, "…but it is still flagged as a section"
    end

    test "root_repo? is false when the project has no live folder" do
      project = @user.maker_projects.create!(name: "Folderless")
      refute Maker::ProjectFolderListing.new(@user, project).root_repo?
    end
  end
end
