require "test_helper"

module Maker
  class ModelIntakeTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mi-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-shelf", "3D Models", nil)
      file("f-benchy", "benchy.stl", "d-shelf")
      dir("d-enc", "Enclosure", "d-shelf")
      file("f-body", "body.stl", "d-enc")
      file("f-manual", "manual.pdf", "d-enc")
      @user.maker_shelves.create!(path: "3D Models")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    test "it creates one model per key, titled from the folder or file name" do
      Maker::ModelIntake.for_user(user: @user)

      titles = @user.maker_models.order(:title).pluck(:title, :origin, :auto_node_id)
      assert_equal [ [ "Enclosure", "auto", "d-enc" ], [ "benchy", "auto", "f-benchy" ] ], titles
    end

    test "a folder model attaches every file in its subtree with the derived role" do
      Maker::ModelIntake.for_user(user: @user)

      model = @user.maker_models.find_by!(auto_node_id: "d-enc")
      assert_equal [ [ "f-body", "model" ], [ "f-manual", "instructions" ] ],
                   model.file_attachments.order(:node_id).pluck(:node_id, :role)
    end

    test "a folder model points at the folder without creating one" do
      Maker::ModelIntake.for_user(user: @user)

      assert_equal "d-enc", @user.maker_models.find_by!(auto_node_id: "d-enc").folder_node_id
      # ensure_library_folder! would have minted Models/<slug>; the sweep must never call it (§14f).
      assert_nil @user.nodes.present.find_by(name: "Models", kind: "dir")
    end

    test "a second sweep creates nothing and attaches nothing" do
      Maker::ModelIntake.for_user(user: @user)
      models = @user.maker_models.count
      atts   = Maker::FileAttachment.where(user: @user).count

      Maker::ModelIntake.for_user(user: @user)

      assert_equal models, @user.maker_models.count
      assert_equal atts, Maker::FileAttachment.where(user: @user).count
    end

    test "a file added later attaches to the model that already exists" do
      Maker::ModelIntake.for_user(user: @user)
      file("f-render", "render.png", "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      model = @user.maker_models.find_by!(auto_node_id: "d-enc")
      assert_includes model.file_attachments.pluck(:node_id), "f-render"
    end

    # DISMISSAL IS PERMANENT AND THE SWEEP MUST RESPECT IT -- otherwise the next tick recreates the
    # row the user just deleted, and they delete it again (§14f).
    test "a dismissed model is not recreated" do
      Maker::ModelIntake.for_user(user: @user)
      @user.maker_models.find_by!(auto_node_id: "d-enc").update!(dismissed_at: Time.current)

      Maker::ModelIntake.for_user(user: @user)

      # ASSERTED ON THE ROW, NOT A TIMESTAMP. §15: a timestamp compared at .to_i cannot fail when
      # both writes land in the same second.
      assert_equal 1, @user.maker_models.where(auto_node_id: "d-enc").count
      assert_predicate @user.maker_models.find_by!(auto_node_id: "d-enc"), :dismissed_at
    end

    # THE SECOND HALF OF DISMISSAL, AND IT NEEDS ITS OWN TEST. Not recreating the ROW is what the
    # test above pins; this pins that the sweep also stops FILING INTO it. Deleting
    # `next if model.dismissed_at.present?` from attach_all left the whole suite green until this
    # existed -- the dismissed-row test never adds a file after the dismissal, so the re-sweep had
    # nothing new to insert and the missing guard cost nothing observable.
    test "a file arriving under a dismissed model is not attached to it" do
      Maker::ModelIntake.for_user(user: @user)
      model = @user.maker_models.find_by!(auto_node_id: "d-enc")
      model.update!(dismissed_at: Time.current)

      file("f-late", "late.stl", "d-enc")
      Maker::ModelIntake.for_user(user: @user)

      assert_not_includes model.file_attachments.reload.pluck(:node_id), "f-late"
    end

    # A FOLDER A PROJECT CLAIMS IS THE PROJECT'S, NOT THE CATALOG'S (2026-09-02). `*` makes
    # `Projects` a shelf, so before this a folder directly under it became a MODEL holding its whole
    # tree: measured on a real share library, `Projects/TheFlightWall_OSS` -- a firmware repo --
    # became a "3D model" with 2305 attachments, 1273 of them source files. Maker::ProjectDiscovery
    # adopts every folder under `Projects/` and Library::ScanJob runs it BEFORE this sweep (§14k),
    # so asking who claims the folder is what expresses the rule without a second copy of
    # ProjectDiscovery's policy living here.
    test "a folder a project claims is not catalogued" do
      @user.maker_projects.create!(name: "Enclosure", slug: "enclosure", folder_node_id: "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      assert_nil @user.maker_models.find_by(auto_node_id: "d-enc")
      # AND ITS FILES ARE LEFT ALONE, which is the half nothing else would notice -- the same
      # both-halves reading the imported-model rule below is pinned on.
      assert_empty Maker::FileAttachment.where(user: @user, node_id: %w[f-body f-manual])
    end

    # UNSCOPED, FOR THE REASON Maker::ProjectDiscovery#adoptable STATES ABOUT ITS OWN `claimed` SET:
    # archiving a project leaves folder_node_id intact, so it still claims its folder. Filtering
    # archived rows out here is how an archived project's folder silently reappears as a model.
    test "an archived project still claims its folder" do
      @user.maker_projects.create!(name: "Enclosure", slug: "enclosure", folder_node_id: "d-enc",
                                   status: "archived", archived_at: Time.current)

      Maker::ModelIntake.for_user(user: @user)

      assert_nil @user.maker_models.find_by(auto_node_id: "d-enc")
    end

    # THE ROW THE OLD RULE ALREADY WROTE STOPS GROWING. A claimed key is dropped before `existing`
    # is even looked up, so an auto model that predates this rule attaches nothing further; clearing
    # it out is Maker::ModelIntake::Prune's job, not a sweep that only ever inserts.
    test "an auto model on a folder a project claims stops attaching" do
      Maker::ModelIntake.for_user(user: @user)
      model = @user.maker_models.find_by!(auto_node_id: "d-enc")
      @user.maker_projects.create!(name: "Enclosure", slug: "enclosure", folder_node_id: "d-enc")
      file("f-late", "late.stl", "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      assert_not_includes model.file_attachments.reload.pluck(:node_id), "f-late"
    end

    test "a folder an imported model already claims is skipped" do
      @user.maker_models.create!(title: "Hand imported", folder_node_id: "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      assert_nil @user.maker_models.find_by(auto_node_id: "d-enc")
      assert_equal 1, @user.maker_models.where(folder_node_id: "d-enc").count
    end

    test "the cap bounds one run and says so" do
      20.times do |i|
        dir("d-cap-#{i}", "cap#{i}", "d-shelf")
        file("f-cap-#{i}", "part.stl", "d-cap-#{i}")
      end

      run = Maker::ModelIntake.for_user(user: @user, cap: 5)

      assert_equal 5, run.created
      assert_equal :capped, run.status
      assert_equal 5, @user.maker_models.count
    end

    # THE STEADY-STATE PASS IS THE ONE THAT RUNS FOREVER -- every 15 minutes, on a library that is
    # already catalogued -- so its cost must not grow with the library. ASSERTED AS CONSTANT, NEVER
    # AS A LITERAL: the counts differ per LIBRARY_BACKEND, so a literal pins one leg and fails the
    # other two (page_query_budget_test.rb's rule).
    #
    # A pass that CREATES models is unavoidably linear (each row needs an INSERT and a slug
    # uniqueness check); this asserts the pass that creates nothing, which is where an N+1 would
    # otherwise hide undetected for the life of the deployment.
    test "a no-op sweep costs the same on a big library as on a small one" do
      Maker::ModelIntake.for_user(user: @user)
      small = count_queries { Maker::ModelIntake.for_user(user: @user) }

      10.times do |i|
        dir("d-more-#{i}", "more#{i}", "d-shelf")
        file("f-more-#{i}", "part.stl", "d-more-#{i}")
        file("f-doc-#{i}", "notes.pdf", "d-more-#{i}")
      end
      Maker::ModelIntake.for_user(user: @user)
      big = count_queries { Maker::ModelIntake.for_user(user: @user) }

      assert_equal small, big
    end

    # THE POINT OF KEYING ON node_id RATHER THAN A PATH. Library::Reconciler's pairing by
    # (content_hash, size) keeps a renamed node's node_id, so renaming the folder in Finder must
    # keep ONE catalog entry -- a path key would abandon the old row and mint a second, and the
    # user would find two models for one folder.
    test "renaming a model folder keeps one model" do
      Maker::ModelIntake.for_user(user: @user)
      model = @user.maker_models.find_by!(auto_node_id: "d-enc")

      @user.nodes.find_by!(node_id: "d-enc").update!(name: "Enclosure v2")
      Maker::ModelIntake.for_user(user: @user)

      assert_equal 1, @user.maker_models.where(auto_node_id: "d-enc").count
      assert_equal model.id, @user.maker_models.find_by!(auto_node_id: "d-enc").id
    end

    # TWO SHELVES MATCHING ONE FOLDER IS NOT AN AMBIGUITY. Shelves are a SET, not an ordered list,
    # so a folder named by both a literal and a wildcard resolves identically either way.
    test "a folder matched by two shelves is catalogued once" do
      @user.maker_shelves.create!(path: "*")
      Maker::ModelIntake.for_user(user: @user)

      assert_equal 1, @user.maker_models.where(auto_node_id: "d-enc").count
    end

    # THE OTHER HALF OF "LOOK, DO NOT TAKE". The assertion above proves no AUTO row is created for a
    # folder an import already claims; this proves the sweep also leaves that folder's FILES alone.
    # Without it, "skipped" could mean "created no row but filed its contents anyway", which is the
    # more damaging half and the one nothing was pinning.
    test "an imported model's files are left unattached by the sweep" do
      imported = @user.maker_models.create!(title: "Hand imported", folder_node_id: "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      assert_empty imported.file_attachments
      assert_empty Maker::FileAttachment.where(user: @user, node_id: %w[f-body f-manual])
    end

    # A NEGATIVE OR ZERO OVERRIDE FALLS BACK RATHER THAN CRASHING A RECURRING JOB. Integer("-5")
    # succeeds, so this cannot be left to the rescue: a negative reaches todo.first(-5), which
    # raises "negative array size" from inside the job with nothing naming the typo that caused it.
    test "a nonsense cap override falls back to the default" do
      %w[-5 0 banana].each do |bad|
        ENV["MODEL_CATALOG_MAX_MODELS"] = bad
        assert_equal Maker::ModelIntake::MAX_MODELS, Maker::ModelIntake.max_models, bad
      end
    ensure
      ENV.delete("MODEL_CATALOG_MAX_MODELS")
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
