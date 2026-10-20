require "test_helper"

module Web
  # THE 3D MODELS VIEW IS SORTED INTO PROJECTS (2026-10-20, Maker::ModelProjects): a group per
  # project whose folder holds a model, by name, then "Not in a project" last; and the plain
  # ungrouped grid when no model is in any project. Same hermetic library and sign-in as
  # models_catalog_test.rb, for the same reason: a cover resolves through ThumbnailMap -> stat_all.
  class ModelsByProjectTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "mbp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def dir(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    # A one-file auto model, keyed on its FILE the way Maker::ModelIntake keys one.
    def model_in(title, parent)
      node_id = "n-#{title.parameterize}"
      @user.nodes.create!(node_id:, name: "#{title}.stl", kind: "file", parent_node_id: parent, mtime: 1, size: 1)
      @user.maker_models.create!(title:, origin: "auto", auto_node_id: node_id).tap do |m|
        m.file_attachments.create!(user: @user, node_id:, role: "model")
      end
    end

    def project_at(name, folder)
      @user.maker_projects.create!(name:).tap { |p| p.update_column(:folder_node_id, folder) }
    end

    test "models are grouped under the project whose folder holds them, loose models last" do
      dir("d-projects", "Projects")
      dir("d-laser", "laser-mount", "d-projects")
      dir("d-laser-models", "models", "d-laser")
      dir("d-catan", "catan", "d-projects")
      dir("d-loose", "3d models")
      laser = project_at("laser mount", "d-laser")
      catan = project_at("catan", "d-catan")
      model_in("Core", "d-laser-models")
      model_in("lasermount", "d-laser-models")
      model_in("robber", "d-catan")
      model_in("Benchy", "d-loose")

      get files_models_path(sort: "title")
      assert_response :success

      heads = css_select(".models-groups .models-group h2.group-head").map { |h| h.text.squish }
      assert_equal [ "catan (1)", "laser mount (2)", "Not in a project (1)" ], heads
      assert_select ".models-group h2.group-head a[href=?]", project_path(catan), text: "catan"
      assert_select ".models-group h2.group-head a[href=?]", project_path(laser), text: "laser mount"

      groups = css_select(".models-groups .models-group").map { |s| s.css(".model-name").map(&:text) }
      assert_equal [ %w[robber], %w[Core lasermount], %w[Benchy] ], groups
      assert_select ".toolbar-count", text: "4 models"
      # ONE thumbs controller around every group, never one per grid.
      assert_select "[data-controller~=thumbs]", count: 1
      assert_select ".models-groups[data-controller=thumbs] .model-card [data-thumbs-target=cell]", count: 4
    end

    test "a filter that empties a project's group drops that group" do
      dir("d-catan", "catan")
      project_at("catan", "d-catan")
      model_in("robber", "d-catan")
      model_in("Benchy", nil)

      get files_models_path(q: "bench")

      assert_select ".models-group", count: 1
      assert_select ".models-group h2.group-head", count: 0, message: "a lone loose group needs no heading"
      assert_select ".models-group .model-name", text: "Benchy"
    end

    test "with no model in any project the page is the plain grid, with no headings" do
      dir("d-catan", "catan")
      project_at("catan", "d-catan")
      model_in("Benchy", nil)
      model_in("Light", nil)

      get files_models_path

      assert_select ".models-group", count: 1
      assert_select "h2.group-head", count: 0
      assert_select ".models-group .model-card", count: 2
    end
  end
end
