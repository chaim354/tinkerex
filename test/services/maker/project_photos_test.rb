require "test_helper"

module Maker
  # Stage 4, S4-1: the ONE definition of a project's photos — folder images plus live entry photos,
  # deduped, name-ordered — shared by the private and the public project page.
  class ProjectPhotosTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "photos@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      @project = @user.maker_projects.create!(name: "Lamp")
      @folder = project_folder_rows!(@user, @project)
    end

    def node!(id, name, parent: @folder.node_id)
      @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent, size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "folder images and live entry photos, once each, by name; a model is not a photo" do
      node!("b", "b.png")
      a = node!("a", "a.jpg")
      node!("m", "part.stl")
      outside = node!("z", "z.png", parent: nil)
      entry = @project.build_log_entries.create!(user: @user, body: "step", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: "z", role: "image")
      entry.file_attachments.create!(user: @user, node_id: "a", role: "image")    # also in the folder: once
      entry.file_attachments.create!(user: @user, node_id: "gone", role: "image") # not live: dropped

      listing = Maker::ProjectFolderListing.new(@user, @project)
      entries = @project.build_log_entries.includes(:file_attachments).to_a
      page_nodes = { "z" => outside, "a" => a }

      rows = Maker::ProjectPhotos.rows(listing:, entries:, page_nodes:)

      assert_equal %w[a.jpg b.png z.png], rows.map { |r| r.node.name }
      assert rows.last.linked?, "an entry photo outside the folder is a linked row"
      refute rows.first.linked?, "a folder image is a folder row"
    end

    test "nothing to show is an empty array, never nil" do
      listing = Maker::ProjectFolderListing.new(@user, @project)
      assert_equal [], Maker::ProjectPhotos.rows(listing:, entries: [], page_nodes: {})
    end
  end
end
