require "test_helper"

module Web
  # Every page here is rendered at two data sizes and must issue the SAME number of queries.
  #
  # WHY CONSTANCY AND NOT A LITERAL: the counts differ per FileLayer backend (chunk resolves file
  # metadata differently from share/s3), so a literal would pin one leg and fail the other two.
  # Constancy is also the property that actually matters — a page that costs 12 queries is fine
  # forever; a page that costs one query per row is a page that dies on real data. The same
  # argument is made at length in test/services/file_layer/adapter_contract.rb.
  #
  # THIS FILE EXISTS BECAUSE projects#show REGRESSED TO LINEAR AND NOTHING NOTICED. Rich text
  # bodies arrived with the project-page overhaul and the eager load was never extended, so the
  # page went from flat to +1 query per build-log entry with the whole suite still green. Nothing
  # in the suite measured query counts on any web page, which is exactly why that was possible.
  class PageQueryBudgetTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    SMALL = 3
    LARGE = 15

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = User.create!(email: "budget@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    # SCHEMA/TRANSACTION and PRAGMA are excluded: they are this page's cost only by accident of
    # being first in the process. The warm-up request in assert_constant_queries is what really
    # keeps them out of the measurement.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # Render once to warm every lazy load (schema, routes, view compilation), then measure twice.
    def assert_constant_queries(path, seed_small, seed_large, label)
      seed_small.call
      get path
      assert_response :success, "#{label} must render before it can be budgeted"
      small = count_queries { get path }

      seed_large.call
      get path
      large = count_queries { get path }

      assert_equal small, large,
                   "#{label} issued #{small} queries at the small size and #{large} at the " \
                   "large one — it grows with the data. Add the missing eager load."
    end

    def node!(id, name)
      @user.nodes.create!(node_id: id, name: name, kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "projects#show does not grow with attachments, tasks or build-log entries" do
      project = @user.maker_projects.create!(name: "Budgeted", status: "active")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          project.tasks.create!(user: @user, title: "task #{id}")
          project.build_log_entries.create!(user: @user, body: "entry #{id}",
                                           logged_at: Time.current)
        end
      end

      assert_constant_queries(project_path(project),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#show")
    end

    test "projects#index does not grow with the number of projects" do
      add = lambda do |prefix, count|
        count.times { |i| @user.maker_projects.create!(name: "#{prefix}#{i}", status: "active") }
      end
      assert_constant_queries(projects_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#index")
    end

    test "models#index does not grow with the number of models" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.maker_models.create!(title: "#{prefix}#{i}", slug: "#{prefix}#{i}")
        end
      end
      assert_constant_queries(models_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "models#index")
    end

    test "models#show does not grow with attachments or print runs" do
      model = @user.maker_models.create!(title: "Shown", slug: "shown")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          model.file_attachments.create!(user: @user, node_id: id, role: "model")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success")
        end
      end
      assert_constant_queries(model_path(model),
                              -> { add.call("ms", SMALL) },
                              -> { add.call("ml", LARGE - SMALL) },
                              "models#show")
    end

    test "files#index folder view does not grow with the number of nodes" do
      add = lambda do |prefix, count|
        count.times { |i| node!("#{prefix}#{i}", "#{prefix}#{i}.stl") }
      end
      assert_constant_queries(files_path,
                              -> { add.call("fs", SMALL) },
                              -> { add.call("fl", LARGE - SMALL) },
                              "files#index (folder)")
    end

    test "trash#index does not grow with the number of tombstones" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.nodes.create!(node_id: "#{prefix}#{i}", name: "#{prefix}#{i}.stl", kind: "file",
                              size: 1, mtime: 1_700_000_000_000_000_000, deleted: true)
        end
      end
      assert_constant_queries(trash_index_path,
                              -> { add.call("ts", SMALL) },
                              -> { add.call("tl", LARGE - SMALL) },
                              "trash#index")
    end
  end
end
