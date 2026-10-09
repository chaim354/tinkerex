require "test_helper"

module Maker
  # THE ONE ANSWER TO "WHICH 3D MODEL DOES THIS FOLDER SHOW?" AND "WHERE DOES /models/:id SEND YOU?"
  # (structural redesign §5.4, slice 5). Rows only, no port: every backend leg runs the same assertions.
  class ModelFolderTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mf-#{SecureRandom.hex(4)}@example.com", password: "x" * 12, confirmed_at: Time.current)
      @dir = @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      @stl = @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", kind: "file", parent_node_id: "d-bracket",
                                 mtime: 1, size: 1, content_hash: "h", current_version_id: "v")
    end

    def model!(origin: "import", folder: "d-bracket", auto: nil, attach: true, dismissed: false)
      m = @user.maker_models.create!(title: "Bracket #{SecureRandom.hex(2)}", origin:, folder_node_id: folder,
                                     auto_node_id: auto, dismissed_at: (Time.current if dismissed))
      m.file_attachments.create!(user: @user, node_id: "n-bracket", role: "model") if attach
      m
    end

    test "an imported model's folder shows that model" do
      m = model!
      assert_equal m, ModelFolder.model_in(@user, "d-bracket")
    end

    test "an auto folder model shows, keyed on folder_node_id" do
      m = model!(origin: "auto", auto: "d-bracket")
      assert_equal m, ModelFolder.model_in(@user, "d-bracket")
    end

    test "a dismissed model and an emptied auto model show nothing" do
      model!(dismissed: true)
      model!(origin: "auto", auto: "d-bracket", attach: false)
      assert_nil ModelFolder.model_in(@user, "d-bracket")
    end

    test "a hidden stale row does not hide a live one in the same folder" do
      model!(origin: "auto", auto: "d-bracket", attach: false)   # older, emptied — hidden
      live = model!
      assert_equal live, ModelFolder.model_in(@user, "d-bracket")
    end

    # THE EMPTIED-AUTO FILTER READS THE EAGER-LOADED ASSOCIATION, NEVER A QUERY PER ROW
    # (model-intake.md: "an emptied auto model is hidden" — off the already-loaded association, not
    # `where.missing`). Several rows can name one folder until `rake models:prune`, and every hidden
    # one OLDER than the model shown is walked past, so the cost must not grow with them. NOT the page
    # budget's job: one model's attachments load in one query with or without the include, which is
    # why page_query_budget_test.rb's model folder stayed green with `.includes` deleted.
    test "model_in costs the same whatever the number of hidden rows before the one it shows" do
      model!(origin: "auto", folder: "d-few", auto: "stale-few", attach: false)
      6.times { |i| model!(origin: "auto", folder: "d-many", auto: "stale-many-#{i}", attach: false) }
      few = model!(folder: "d-few")
      many = model!(folder: "d-many")

      queries = lambda do |folder|
        n = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| n += 1 unless payload[:name] == "SCHEMA" }
        shown = ModelFolder.model_in(@user, folder)
        [ shown, n ]
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end
      shown_few, few_count = queries.call("d-few")
      shown_many, many_count = queries.call("d-many")
      assert_equal [ few, many ], [ shown_few, shown_many ]
      assert_equal few_count, many_count, "model_in issued #{few_count} queries past 1 hidden row and #{many_count} past 6"
    end

    test "another user's model in a same-named node id shows nothing" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: "x" * 12, confirmed_at: Time.current)
      other.maker_models.create!(title: "Theirs", folder_node_id: "d-bracket")
      assert_nil ModelFolder.model_in(@user, "d-bracket")
    end

    test "a folder model lands on its live folder" do
      m = model!
      assert_equal "d-bracket", ModelFolder.landing_folder_id(@user, m)
    end

    # ONE MODEL THROUGHOUT, AND IT IS THE ONE THE FOLDER SHOWS (the control assertion says so). A
    # second model for the project clause would be refused by the "shows THIS model" check before the
    # claim was ever asked — mutation-checked: deleting the claim line stayed green until this test
    # stopped creating one model per clause.
    test "no landing for a one-file model, a trashed folder, or a project's folder" do
      one_file = model!(origin: "auto", folder: nil, auto: "n-bracket")
      assert_nil ModelFolder.landing_folder_id(@user, one_file)

      m = model!
      assert_equal "d-bracket", ModelFolder.landing_folder_id(@user, m)

      @dir.update!(deleted: true)
      assert_nil ModelFolder.landing_folder_id(@user, m)
      @dir.update!(deleted: false)

      @user.maker_projects.create!(name: "Shelf").update_column(:folder_node_id, "d-bracket")
      assert_equal m, ModelFolder.model_in(@user, "d-bracket"), "the folder still names this model"
      assert_nil ModelFolder.landing_folder_id(@user, m)
    end

    test "only the model the folder actually shows lands there" do
      shown = model!
      second = model!
      assert_equal "d-bracket", ModelFolder.landing_folder_id(@user, shown)
      assert_nil ModelFolder.landing_folder_id(@user, second)
    end
  end
end
