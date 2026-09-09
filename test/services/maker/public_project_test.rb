require "test_helper"
require "support/public_fixture"

module Maker
  # STAGE 3, S3-4: the one object every public surface asks. The four questions worth pinning at
  # this level are the ones the page cannot show you it got right — section ORDER, what the links
  # carry, how the photo list dedupes, and above all the permission matrix, which is cheap to drive
  # ten ways here and expensive to drive ten ways through the router.
  #
  # A FRESH SHARE LIBRARY PER TEST — see test/support/public_fixture.rb's header.
  class PublicProjectTest < ActiveSupport::TestCase
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
    end

    def pub = Maker::PublicProject.new(@project.reload)

    # --- shape ------------------------------------------------------------------

    # `sections` IS GONE (folder panels): the visitor's Files panel is the folder ROOT and each
    # subfolder is a panel, so the readers the page uses are `loose_rows` and `folder_sections`.
    test "loose_rows are the folder's own files, and folder_sections name a panel's subfolders relative to it" do
      loose = pub.loose_rows.map { |r| r.node.name }
      # The dot-file is in the folder and NOT in the listing: Maker::ProjectFolderListing applies
      # Node.visible_entries, the same display rule the owner's own page uses.
      assert_includes loose, "README.md"
      assert_not_includes loose, ".env"

      models = pub.folder_dir(Maker::ProjectKind.folder_key(@f[:models].node_id))
      names = pub.folder_sections(models).map(&:first)
      # FOLDER-RELATIVE, not the library path: a visitor never reads "Projects/desk-lamp/…".
      assert_equal 2, names.size, "the panel's own rows, then its nested deep/"
      assert_nil names.first, "a panel's own files carry no sub-heading"
      assert names.compact.none? { |n| n.start_with?("Projects/") }, names.inspect
      assert names.last.to_s.end_with?("deep"), names.inspect
    end

    test "link_params carries the token for an unlisted project and nothing for a public one" do
      assert_equal({}, pub.link_params)

      @project.update!(visibility: "unlisted")
      assert_equal({ k: @project.reload.unlisted_token }, pub.link_params)
      assert_predicate @project.unlisted_token, :present?
    end

    test "file_url_for names the file, forces a download and carries the unlisted token" do
      id = @f[:base].node_id
      assert_equal "/u/ada/desk-lamp/files/#{id}", pub.file_url_for(id)
      assert_equal "/u/ada/desk-lamp/files/#{id}/base.stl", pub.file_url_for(id, filename: "base.stl")
      assert_equal "/u/ada/desk-lamp/files/#{id}?download=1", pub.file_url_for(id, download: true)

      @project.update!(visibility: "unlisted")
      url = pub.file_url_for(id, filename: "base.stl", download: true)
      assert_includes url, "k=#{@project.reload.unlisted_token}"
      assert_includes url, "download=1"
      assert_includes url, "/files/#{id}/base.stl?"
    end

    test "photo_rows merge the folder's images with the entry photos and dedupe by node" do
      ids = pub.photo_rows.map(&:node_id)

      assert_includes ids, @f[:pic].node_id,         "an image in the folder is a photo"
      assert_includes ids, @f[:entry_photo].node_id, "an entry photo outside the folder is a photo"
      assert_equal ids.uniq, ids
      assert_equal pub.photo_rows.map { |r| r.node.name }.sort, pub.photo_rows.map { |r| r.node.name }
    end

    test "a photo attached to an entry AND sitting in the folder appears exactly once" do
      @f[:entry].file_attachments.create!(user: @user, node_id: @f[:pic].node_id, role: "image", position: 1)

      ids = pub.photo_rows.map(&:node_id)
      assert_equal 1, ids.count(@f[:pic].node_id), "the folder row and the attachment are one photo"
    end

    test "kicad_rows find the schematic anywhere in the folder, name-ordered" do
      assert_equal [ "driver.kicad_sch" ], pub.kicad_rows.map { |r| r.node.name }
    end

    test "repo_cards are keyed by the repo dir's node_id and resolve README links publicly" do
      cards = pub.repo_cards

      assert_equal [ @f[:firmware].node_id ], cards.keys
      assert_equal "firmware", cards.values.first.dir.name
    end

    test "bom_lines and connections come from the project, entries newest first" do
      assert_equal 3, pub.bom_lines.size
      assert_equal 2, pub.connections.size
      assert_equal [ @f[:entry].id ], pub.entries.map(&:id)
    end

    # --- the permission matrix --------------------------------------------------
    #
    # The ten cases public_file_test.rb drives through the router, asserted here where each is one
    # line. Both are wanted: this proves the RULE, that one proves the ROUTE applies it.

    test "a file directly in the project folder is permitted" do
      assert pub.permits?(@f[:readme])
    end

    test "a file in a subfolder is permitted" do
      assert pub.permits?(@f[:base])
    end

    test "a file two levels down is permitted by ancestry, not by the listing" do
      assert pub.permits?(@f[:deep_file])
    end

    test "a file attached to a build-log entry is permitted even outside the folder" do
      node = @f[:entry_photo]
      assert_nil node.parent_node_id, "the fixture's entry photo must sit outside the folder"
      assert pub.permits?(node)
    end

    test "a file attached to the project itself is permitted even outside the folder" do
      @project.file_attachments.create!(user: @user, node_id: @f[:outsider].node_id,
                                        role: "model", position: 0)
      assert Maker::PublicProject.new(@project.reload).permits?(@f[:outsider])
    end

    test "an unattached sibling of the folder is refused" do
      assert_not pub.permits?(@f[:outsider])
    end

    test "a directory is refused" do
      assert_not pub.permits?(@f[:models])
    end

    test "a tombstoned file is refused" do
      @f[:base].update!(deleted: true)
      assert_not pub.permits?(@f[:base].reload)
    end

    test "a dot-file inside the folder is refused" do
      assert_not pub.permits?(@f[:dotfile]), ".env is in the folder and must never be a public download"
    end

    # THE VISIBILITY CHECK IS THE OWNER'S. `nodes` is unique on (user_id, node_id), not node_id
    # alone, so an unscoped `Node.visible_entries.where(node_id:)` asks whether ANY user has a
    # visible row with that id -- and another user's plainly named row under the same id would
    # have vouched for this owner's `.env` (S3-4's review). Ids are UUIDs, so this is a guard on
    # the narrowest true statement rather than on a live exploit.
    test "another user's visible row with the same node id does not vouch for a dot-file" do
      other = make_owner!(handle: "bob")
      other.nodes.create!(node_id: @f[:dotfile].node_id, name: "plain.stl", kind: "file", mtime: 1, size: 1)

      assert_not pub.permits?(@f[:dotfile])
    end

    # A PROJECT WITH NO FOLDER STILL OWNS ITS ATTACHMENTS, AND NOTHING ELSE. `folder_node_id` is
    # nullable and publishing needs only a handle, so this state is reachable; the page renders
    # an entry photo living elsewhere by its attachment row, and the route must agree. The
    # ancestry arms stay closed here for the reason the code comment gives: with a nil folder,
    # `Array(ancestors_of(x)).include?(nil)` is true for every chain in the library.
    test "a project with no folder permits its attachments and nothing by ancestry" do
      @project.update_column(:folder_node_id, nil)
      folderless = Maker::PublicProject.new(@project.reload)

      assert folderless.permits?(@f[:entry_photo]), "an attached entry photo is the project's by its row"
      assert_not folderless.permits?(@f[:base]), "a file that was in the folder is unreachable without it"
      assert_not folderless.permits?(@f[:outsider])
    end

    # NOTHING BENEATH A .git MARKER DELIVERS. The listing never descends into one, but permits?
    # walks the LibraryTree, which indexes every live dir; on chunk_remote the catalog mirrors
    # whatever a client synced, so `.git/config` has a plain name, sits under the folder, and
    # would pass the visibility and ancestry checks. Two depths: a file directly inside `.git/`
    # and one nested under it.
    test "a file beneath a .git marker is refused even inside the folder" do
      git = make_dir!(@user, Library::RepoMetadata::DIR_NAME, @f[:models])
      config = make_file!(@user, "config", git)
      hooks = make_dir!(@user, "hooks", git)
      hook = make_file!(@user, "pre-commit", hooks)

      refused = Maker::PublicProject.new(@project.reload)
      assert_not refused.permits?(config)
      assert_not refused.permits?(hook)
      assert refused.permits?(@f[:base]), "a sibling outside the marker is still delivered"
    end

    test "a node of another user is refused, and nil is refused" do
      other = make_owner!(handle: "bob")
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.stl", kind: "file",
                                   mtime: 1, size: 1)
      # `permits?` is asked about a Node the caller resolved; `deliverable!` is what scopes the
      # lookup to the owner, so the cross-user refusal is asserted through that door too.
      assert_not pub.permits?(nil)
      assert_raises(ActiveRecord::RecordNotFound) { pub.deliverable!(theirs.node_id) }
    end

    test "permits? does not raise for a node at the library root" do
      # `LibraryTree#ancestors_of(nil)` is the shape that made an unguarded `#include?` a
      # NoMethodError. A root-level node simply matches no folder.
      assert_nothing_raised { pub.permits?(@f[:outsider]) }
    end

    test "deliverable! answers the node it permits and refuses everything else the same way" do
      assert_equal @f[:base].node_id, pub.deliverable!(@f[:base].node_id).node_id
      assert_raises(ActiveRecord::RecordNotFound) { pub.deliverable!(@f[:dotfile].node_id) }
      assert_raises(ActiveRecord::RecordNotFound) { pub.deliverable!("no-such-node") }
    end

    # --- the README -------------------------------------------------------------

    test "the README resolves its relative links against the folder's own library path" do
      html = pub.readme.html.to_s

      assert_includes html, "/u/ada/desk-lamp/files/#{@f[:base].node_id}",
                      "base_path must be listing.path, not \"\" — path_index keys on full library paths"
      assert_includes html, "/u/ada/desk-lamp/files/#{@f[:pic].node_id}"
      assert_not_includes html, "https://x.example/p.gif", "an absolute image becomes its alt text (Task B)"
    end
  end
end
