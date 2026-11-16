require "test_helper"

module Maker
  # WHICH FOLDER A MODEL SITS IN (Maker::Model.placements), the one answer the 3D models view's
  # project groups and cards, the Add-model picker, search and a tag's page all read. It was three
  # rules that disagreed: the group read one key, the card another, and search a third.
  #
  # BACKEND-NEUTRAL FIXTURES, as model_projects_test.rb: the function reads `nodes` and never the
  # port, so a bare create! is a complete fixture.
  class ModelPlacementsTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pl-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-models", "Models", nil)
      dir("d-bracket", "bracket", "d-models")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def attach(model, node_id, role: "model", position: 0)
      model.file_attachments.create!(user: @user, node_id:, role:, position:)
    end

    # A sweep-made model: its key is a FOLDER for a folder model, the FILE for a one-file model.
    def auto_model(title, key, folder: nil)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: key, folder_node_id: folder)
    end

    def places(models = @user.maker_models.includes(:file_attachments).order(:id).to_a)
      Maker::Model.placements(@user, models, tree: Maker::LibraryTree.new(@user))
    end

    def statements
      out = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        out << payload[:sql] unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
      end
      yield
      out
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    test "a folder model sits in its own folder, and a one-file model in the folder that holds its file" do
      file("n-base", "base.stl", "d-bracket")
      bracket = auto_model("bracket", "d-bracket", folder: "d-bracket").tap { |m| attach(m, "n-base") }
      file("n-clip", "clip.stl", "d-models")
      clip = auto_model("clip", "n-clip").tap { |m| attach(m, "n-clip") }

      assert_equal({ bracket.id => "d-bracket", clip.id => "d-models" }, places)
    end

    # THE LIBRARY ROOT IS A PLACE. nil is its id, so the entry is PRESENT with a nil value; a model
    # that cannot be placed has no entry at all (below), and a caller tells the two apart by the key.
    test "a file at the top of the library sits in the library root" do
      file("n-root", "root.stl", nil)
      model = auto_model("root", "n-root").tap { |m| attach(m, "n-root") }

      result = places
      assert result.key?(model.id), "a model at the root lost its place"
      assert_nil result[model.id]
    end

    # AN IMPORT WITH NO FOLDER IS PLACED BY ITS FIRST FILE, WHATEVER THAT FILE IS. The card used to
    # read its first MESH instead, so a kit whose picture sat in a project's folder and whose mesh
    # sat elsewhere was grouped under the project and labelled with the other folder.
    test "an import sits in its folder, and one with no folder where its first file is" do
      kit = @user.maker_models.create!(title: "kit", origin: "import", folder_node_id: "d-bracket")
      file("n-pic", "pic.jpg", "d-models")
      file("n-mesh", "mesh.stl", "d-bracket")
      loose = @user.maker_models.create!(title: "loose", origin: "import")
      attach(loose, "n-pic", role: "image", position: 0)
      attach(loose, "n-mesh", position: 1)

      assert_equal({ kit.id => "d-bracket", loose.id => "d-models" }, places)
    end

    test "a model with nothing to place it by has no entry" do
      @user.maker_models.create!(title: "bare", origin: "import")
      # A key with no row behind it at all: nothing says where it was.
      auto_model("ghost", "n-never")

      assert_equal({}, places)
    end

    # THE CHOSEN READING OF A KEY IN THE TRASH: the model keeps the folder that held it. A tombstone
    # still has its parent, and Maker::AttachmentReaper clears the model's rows only after the grace
    # window, so until then the group heading (which always read the tombstone) and the card (which
    # did not, and showed no folder) now agree. One sentence for a file and for a folder alike.
    test "a model whose file or folder is in the trash keeps the folder that held it" do
      file("n-clip", "clip.stl", "d-models")
      clip = auto_model("clip", "n-clip").tap { |m| attach(m, "n-clip") }
      file("n-base", "base.stl", "d-bracket")
      bracket = auto_model("bracket", "d-bracket", folder: "d-bracket").tap { |m| attach(m, "n-base") }
      @user.nodes.where(node_id: %w[n-clip n-base d-bracket]).update_all(deleted: true)

      assert_equal({ clip.id => "d-models", bracket.id => "d-models" }, places)
    end

    # CONSTANT IN QUERIES WHATEVER THE CALLER LOADED. Only a model with neither key is placed by its
    # first file, and search and a tag's page hand over models with no files loaded: the function
    # reads those models' files itself, in one query, rather than once per model.
    test "the lookup does not grow with the models, even when their files are not loaded" do
      add = lambda do |prefix, count|
        count.times do |i|
          file("n-#{prefix}#{i}", "#{prefix}#{i}.stl", "d-models")
          attach(@user.maker_models.create!(title: "#{prefix}#{i}", origin: "import"), "n-#{prefix}#{i}")
        end
      end
      measure = lambda do
        models = @user.maker_models.order(:id).to_a
        tree = Maker::LibraryTree.new(@user)
        statements { Maker::Model.placements(@user, models, tree:) }.size
      end

      add.call("s", 2)
      small = measure.call
      add.call("l", 6)
      large = measure.call

      assert_equal small, large, "placements issued #{small} queries for 2 models and #{large} for 8"
      assert_equal 8, places(@user.maker_models.order(:id).to_a).size, "premise: every one of them was placed"
    end

    # AND IT READS NO FILE ROW THE CALLER ALREADY HOLDS. The 3D models view loads every model's
    # files for the covers; a second read of them here would be that page's largest query twice.
    test "files the caller loaded are not read again" do
      file("n-pic", "pic.jpg", "d-models")
      attach(@user.maker_models.create!(title: "loose", origin: "import"), "n-pic", role: "image")
      models = @user.maker_models.includes(:file_attachments).order(:id).to_a
      tree = Maker::LibraryTree.new(@user)

      issued = statements { assert_equal [ "d-models" ], Maker::Model.placements(@user, models, tree:).values }
      assert_empty issued.grep(/maker_file_attachments/), "the loaded files were read again"
      assert_equal 1, issued.size, "one pluck places a file key: #{issued.inspect}"
    end
  end
end
