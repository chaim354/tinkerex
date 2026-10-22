require "test_helper"

module Maker
  class ModelTest < ActiveSupport::TestCase
    setup do
      # A hermetic library: one test here calls ensure_library_folder!, which goes through the port
      # and really creates Models/<slug>. This suite pinned embedded chunk until Arc D Part 2; on
      # the ambient backend it would make real Aws calls on the s3 leg (the stub is opt-in per
      # file) or need a live sync server on chunk_remote.
      @root = use_fresh_share_library!
      @user = User.create!(email: "model-#{SecureRandom.hex(4)}@example.com")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "valid with a title" do
      assert @user.maker_models.build(title: "Articulated Dragon").valid?
    end

    test "title is required" do
      m = @user.maker_models.build(title: nil)
      assert_not m.valid?
      assert_includes m.errors[:title], "can't be blank"
    end

    test "slug is auto-generated from the title" do
      m = @user.maker_models.create!(title: "Articulated Dragon v2!")
      assert_equal "articulated-dragon-v2", m.slug
    end

    test "slug disambiguates on collision instead of failing" do
      first  = @user.maker_models.create!(title: "Benchy")
      second = @user.maker_models.create!(title: "Benchy")
      assert_equal "benchy", first.slug
      assert_equal "benchy-2", second.slug
    end

    test "same slug allowed for a different user" do
      @user.maker_models.create!(title: "Benchy")
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      assert_equal "benchy", other.maker_models.create!(title: "Benchy").slug
    end

    test "explicit slug is respected and normalized" do
      m = @user.maker_models.create!(title: "Dragon", slug: "My Custom Slug")
      assert_equal "my-custom-slug", m.slug
    end

    test "a symbol-only title still gets a usable slug" do
      m = @user.maker_models.create!(title: "★★★")
      assert_equal "model", m.slug
      m2 = @user.maker_models.create!(title: "©®™")
      assert_equal "model-2", m2.slug
    end

    test "print_status defaults to want_to_print and is validated" do
      m = @user.maker_models.create!(title: "x")
      assert_equal "want_to_print", m.print_status
      assert_not @user.maker_models.build(title: "y", print_status: "bogus").valid?
    end

    test "to_param is the slug" do
      m = @user.maker_models.create!(title: "Cool Thing")
      assert_equal "cool-thing", m.to_param
    end

    test "destroyed with the user" do
      @user.maker_models.create!(title: "x")
      assert_difference "Maker::Model.count", -1 do
        @user.destroy!
      end
    end

    test "cover_node_id prefers an explicit override, then image, then model, else nil" do
      m = @user.maker_models.create!(title: "Lamp")
      %w[mdl img].each { |id| @user.nodes.create!(node_id: id, name: "#{id}.bin", kind: "file") }
      assert_nil m.cover_node_id

      m.file_attachments.create!(user: @user, node_id: "mdl", role: "model", position: 0)
      m.file_attachments.create!(user: @user, node_id: "img", role: "image", position: 1)
      assert_equal "img", m.reload.cover_node_id, "image wins over model"

      m.update!(cover_node_id: "mdl")
      assert_equal "mdl", m.reload.cover_node_id, "explicit override wins over image"
    end

    test "cover falls back to the first model file when there is no image" do
      m = @user.maker_models.create!(title: "Gear")
      %w[src g1].each { |id| @user.nodes.create!(node_id: id, name: "#{id}.bin", kind: "file") }
      m.file_attachments.create!(user: @user, node_id: "src", role: "source_archive", position: 0)
      m.file_attachments.create!(user: @user, node_id: "g1", role: "model", position: 1)
      assert_equal "g1", m.reload.cover_node_id
    end

    test "cover falls back to the first attachment of any role when no image or model" do
      m = @user.maker_models.create!(title: "Docs")
      @user.nodes.create!(node_id: "pdf1", name: "pdf1.pdf", kind: "file")
      m.file_attachments.create!(user: @user, node_id: "pdf1", role: "instructions", position: 0)
      assert_equal "pdf1", m.reload.cover_node_id
    end

    test "tag_list reads and writes tags, normalized and de-duped" do
      m = @user.maker_models.create!(title: "Dragon")
      m.tag_list = "Dragon, articulated ,, dragon"
      m.save!
      assert_equal %w[articulated dragon], m.reload.tag_list.split(", ").sort
      assert_equal 2, @user.maker_tags.count
    end

    test "ensure_library_folder! creates Models/<slug> and stores its node_id" do
      m = @user.maker_models.create!(title: "Desk Dragon")
      folder = m.ensure_library_folder!(@user)
      assert_equal m.folder_node_id, folder.node_id
      assert_equal "dir", folder.kind
      assert_equal "desk-dragon", folder.name
      assert_equal "Models", @user.nodes.find_by!(node_id: folder.parent_node_id).name
    end

    test "print_settings stores and returns a Hash, nil by default" do
      m = @user.maker_models.create!(title: "x", print_settings: { "material" => "PET" })
      assert_equal({ "material" => "PET" }, m.reload.print_settings)
      assert_nil @user.maker_models.create!(title: "y").print_settings
    end

    test "an existing model is import-origin without a backfill" do
      model = @user.maker_models.create!(title: "Benchy")
      assert_equal "import", model.origin
      assert_nil model.auto_node_id
      assert_nil model.dismissed_at
    end

    test "two auto models cannot claim one node" do
      @user.maker_models.create!(title: "A", origin: "auto", auto_node_id: "n-1")
      assert_raises(ActiveRecord::RecordNotUnique) do
        @user.maker_models.create!(title: "B", origin: "auto", auto_node_id: "n-1")
      end
    end

    test "catalogued excludes dismissed auto models and keeps import models" do
      keep      = @user.maker_models.create!(title: "Imported")
      auto      = @user.maker_models.create!(title: "Auto", origin: "auto", auto_node_id: "n-2")
      dismissed = @user.maker_models.create!(title: "Gone", origin: "auto", auto_node_id: "n-3",
                                             dismissed_at: Time.current)

      ids = @user.maker_models.catalogued.pluck(:id)
      assert_includes ids, keep.id
      assert_includes ids, auto.id
      assert_not_includes ids, dismissed.id
    end
  end
end
