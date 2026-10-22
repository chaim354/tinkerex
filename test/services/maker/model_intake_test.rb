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
    # became a "3D model" with 2305 attachments, 1273 of them source files. Asking WHO CLAIMS the
    # folder -- a project row, or Maker::ProjectDiscovery by position before the row exists (the
    # positional tests below) -- is what expresses the rule without a second copy of
    # ProjectDiscovery's policy living here, and without depending on discovery having run first.
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

    # A FOLDER DISCOVERY WILL ADOPT IS CLAIMED BEFORE IT IS ADOPTED (F-S07-1). The claim used to be
    # only the ROWS that existed when this sweep ran, and "not adopted YET" was left to running
    # discovery first -- which discovery's cap and chunk_remote's three unsequenced schedules both
    # defeat, leaving a project AND a model. Maker::ProjectDiscovery.positional_claims is the third
    # claimant: there is no project row here at all, and `lamp` is still not the catalog's.
    # `3D Models/Enclosure` from setup is the POSITIVE CONTROL -- a sweep that catalogued nothing
    # at all would pass every assertion before it.
    test "a folder discovery will adopt is not catalogued before it is adopted" do
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "lamp", "d-projects")
      dir("d-cad", "cad", "d-lamp")
      file("f-part", "part.stl", "d-cad")

      Maker::ModelIntake.for_user(user: @user)

      assert_nil @user.maker_models.find_by(auto_node_id: "d-lamp"),
                 "`lamp` became one model before discovery reached it -- the claim lost discovery's position"
      assert_empty Maker::FileAttachment.where(user: @user, node_id: "f-part")
      assert @user.maker_models.exists?(auto_node_id: "d-enc"), "the sweep still catalogues"
    end

    # DISCOVERY'S OWN RULE DECIDES, NEVER A PATH TEST. `.scratch` sits directly under `Projects/`,
    # but discovery will never adopt it (`ProjectDiscovery.adoptable_name?`'s dot rule), so it is
    # nobody's claim and stays an ordinary folder under the `*` shelf. A reader spelled "the parent
    # is the Projects root" would hide it from the catalog forever while no project could hold it.
    test "a dot-folder under Projects is still catalogued" do
      dir("d-projects", "Projects", nil)
      dir("d-scratch", ".scratch", "d-projects")
      file("f-x", "x.stl", "d-scratch")

      Maker::ModelIntake.for_user(user: @user)

      model = @user.maker_models.find_by(auto_node_id: "d-scratch")
      assert model, "a folder discovery will never adopt was treated as claimed"
      assert_equal [ "f-x" ], model.file_attachments.pluck(:node_id)
    end

    # A CAPPED DISCOVERY LEAVES NO MODEL BEHIND IT -- the hole the cap opened even inside
    # Library::ScanJob's own discover -> file -> catalogue sequence. `cap: 1` adopts Alpha (ORDER BY
    # node_id); Beta waits for discovery's next run, and until then it is still discovery's. The
    # projects assertion is the PRECONDITION: without a folder left unadopted this proves nothing.
    test "a capped discovery leaves no auto model over the folders it has not reached" do
      dir("d-projects", "Projects", nil)
      dir("d-alpha", "Alpha", "d-projects")
      file("f-a", "a.stl", "d-alpha")
      dir("d-beta", "Beta", "d-projects")
      file("f-b", "b.stl", "d-beta")
      Maker::ProjectDiscovery.for_user(user: @user, cap: 1)
      assert_equal %w[d-alpha], @user.maker_projects.pluck(:folder_node_id),
                   "precondition: the cap must leave Beta unadopted"

      Maker::ModelIntake.for_user(user: @user)

      assert_empty @user.maker_models.where(auto_node_id: %w[d-alpha d-beta]).pluck(:title),
                   "a folder past discovery's cap became one model"
      assert_empty Maker::FileAttachment.where(user: @user, node_id: %w[f-a f-b])
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

    # A NO-OP SWEEP WRITES NOTHING (F-S07-2, 2026-10-19). Constant in query count is the test
    # above; this is what those queries ARE. The sweep used to re-send one
    # `INSERT … ON CONFLICT DO NOTHING` carrying every file it owns, every tick -- a write
    # statement, so on SQLite it took the one write lock in order to write nothing, every fifteen
    # minutes, forever. attach_all now plucks the pairs that exist and inserts only the missing
    # ones, Maker::ProjectIntake#attach's shape.
    #
    # THE FIRST SWEEP IS THE POSITIVE CONTROL. It writes (the models, their attachments), so a
    # helper that cannot see a write at all -- a wrong event name, a pattern that matches nothing --
    # goes red here instead of passing the assertion that matters (§14e).
    test "a sweep over an unchanged library writes nothing" do
      assert_not_empty writes_during { Maker::ModelIntake.for_user(user: @user) },
                       "precondition: the first sweep writes, so the helper can see a write"

      assert_empty writes_during { Maker::ModelIntake.for_user(user: @user) },
                   "a sweep over an unchanged library wrote"
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
    # so a folder named by both a literal and a wildcard resolves identically either way. A
    # top-level `Models/` is the built-in case: both `*` and `Models` name it.
    test "a folder matched by two shelves is catalogued once" do
      dir("d-models", "Models", nil)
      dir("d-vase", "Vase", "d-models")
      file("f-vase", "vase.stl", "d-vase")

      Maker::ModelIntake.for_user(user: @user)

      assert_equal 1, @user.maker_models.where(auto_node_id: "d-vase").count
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

    # count_queries' subscription, kept to the statements that WRITE -- the ones that take
    # SQLite's single write lock. Returns the SQL rather than a count, so a red run names the
    # statement that wrote.
    WRITE_SQL = /\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i

    def writes_during(&block)
      writes = []
      collector = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(WRITE_SQL) }
      ActiveSupport::Notifications.subscribed(collector, "sql.active_record", &block)
      writes
    end
  end
end
