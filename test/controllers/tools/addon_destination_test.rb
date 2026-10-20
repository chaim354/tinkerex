require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  # WHERE A TOOL'S SAVE STARTS (structural redesign spec §7, as slice 4's plan amended it): the four
  # steps of Tools::AddonsController#tool_destination_node_id, read off the two attributes the shipped
  # bundles seed their "Save into" field from (`data-addon-default-folder-value` /
  # `-label-value`). Rows are created directly and no port call is made, so every backend leg runs
  # the same assertions.
  class AddonDestinationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    MANIFEST = {
      "key" => "destkit", "title" => "Dest Kit", "icon" => "✏️", "description" => "Destinations",
      "api_version" => "1", "entry" => "dest.js"
    }.freeze

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST ], assets: { "destkit/dest.js" => "export default { mount() {} }" }
      )
      @user = User.create!(email: "dest-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown do
      Maker::Addons::Source.reset!
      Rails.cache = @prior_cache
      FileLayer.reset!
    end

    def dir(id, name, parent = nil, deleted: false)
      @user.nodes.create!(node_id: id, name:, kind: "dir", parent_node_id: parent, deleted:, mtime: 1, size: 0)
    end

    def file(id, name, parent, deleted: false)
      @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent, deleted:,
                          mtime: 1, size: 1, content_hash: "h-#{id}", current_version_id: "v-#{id}")
    end

    # A saved state whose output is `node_id`, touched at `at` — `updated_at` is what orders "most
    # recent", so tests set it explicitly rather than trusting creation order (memory: a sort fixture
    # must disagree with the default order, or the mutation reads green).
    def saved(node_id, at:, key: "destkit")
      state = @user.maker_addon_states.create!(addon_key: key, name: "box #{node_id}", data: {})
      state.files.create!(node_id:, role: "output")
      state.update_columns(updated_at: at)
      state
    end

    # ONE STATE WHOSE TWO SAVES PUT THEIR OUTPUT IN TWO FOLDERS: revision 1 in `d-old`, revision 2 in
    # `d-new`. A revision that renamed its output, or was saved into another folder, leaves the earlier
    # row in place on purpose (Maker::Addons::LibraryOutput#upsert_file!). Both rows hold position 0
    # and the revision-1 row is created FIRST, so creation order and the old (position, id) tiebreak
    # both answer `d-old`; only the stored revision answers `d-new`.
    def revised_across_folders(at:)
      dir("d-old", "old")
      dir("d-new", "new")
      file("n-v1", "v1.svg", "d-old")
      file("n-v2", "v2.svg", "d-new")
      state = @user.maker_addon_states.create!(addon_key: "destkit", name: "revised box", data: {}, revision: 2)
      state.files.create!(node_id: "n-v1", role: "output", revision: 1)
      state.files.create!(node_id: "n-v2", role: "output", revision: 2)
      state.update_columns(updated_at: at)
      state
    end

    def assert_default(node_id, label)
      assert_response :success
      assert_select "[data-controller='addon'][data-addon-default-folder-value=?]", node_id.to_s
      assert_select "[data-controller='addon'][data-addon-default-folder-label-value=?]", label
    end

    test "with nothing saved, a tool starts at the library root" do
      get tools_addon_path("destkit")
      assert_default "", "/ (library root)"
    end

    test "?in= naming a live folder of the user's wins over everything else" do
      dir("d-jigs", "jigs")
      dir("d-cad", "cad")
      file("n-old", "old.svg", "d-cad")
      saved("n-old", at: 1.hour.ago)
      get tools_addon_path("destkit", in: "d-jigs")
      assert_default "d-jigs", "/jigs"
    end

    test "a stale, foreign, file or non-String ?in= falls through to the next step" do
      dir("d-cad", "cad")
      dir("d-jigs", "jigs")
      file("n-old", "old.svg", "d-cad")
      saved("n-old", at: 1.hour.ago)
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "d-theirs", name: "theirs", kind: "dir", mtime: 1, size: 0)

      [ "gone", "d-theirs", "n-old" ].each do |stale|
        get tools_addon_path("destkit", in: stale)
        assert_default "d-cad", "/cad"
      end
      # THE ARRAY NAMES A LIVE FOLDER OF THE USER'S THAT IS NOT STEP 3'S ANSWER, which is the only
      # shape in which refusing it is visible: unguarded, the IN lookup resolves `d-jigs` and the tool
      # starts there. Naming `d-cad` instead — step 3's own answer — passed over a deleted guard
      # (measured), because the IN lookup and the fall-through then agree.
      get "#{tools_addon_path('destkit')}?in[]=d-jigs&in[]=gone"
      assert_default "d-cad", "/cad"
    end

    test "with no ?in=, the tool starts where its most recent live output is" do
      dir("d-new", "new")
      dir("d-old", "old")
      # Created FIRST but touched LAST, so creation order and recency disagree.
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      file("n-old", "old.svg", "d-old")
      saved("n-old", at: 2.days.ago)
      get tools_addon_path("destkit")
      assert_default "d-new", "/new"
    end

    # EACH SKIPPED OUTPUT SITS IN A FOLDER OF ITS OWN, so skipping it is visible. The trashed one used
    # to share `d-live` with the answer, and dropping `outputs.deleted` passed (measured): landing on
    # the tombstone named the same folder as skipping it did.
    test "a trashed output, or one whose folder is gone, is skipped for the next live one" do
      dir("d-live", "live")
      dir("d-elsewhere", "elsewhere")
      dir("d-dead", "dead", deleted: true)
      file("n-live", "live.svg", "d-live")
      saved("n-live", at: 3.days.ago)
      file("n-trashed", "trashed.svg", "d-elsewhere", deleted: true)
      saved("n-trashed", at: 1.minute.ago)
      file("n-orphan", "orphan.svg", "d-dead")
      saved("n-orphan", at: 2.minutes.ago)
      # ANOTHER USER OWNS LIVE ROWS UNDER THE SAME TWO IDS, because `node_id` is unique only per user
      # (index_nodes_on_user_id_and_node_id). Both node joins in #latest_output_folder are scoped by
      # user; drop either scope and this user's trashed output resolves through THEIR live file (the
      # page names their folder), or this user's dead folder through THEIR live dir.
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "d-theirs", name: "theirs", kind: "dir", mtime: 1, size: 0)
      other.nodes.create!(node_id: "n-trashed", name: "trashed.svg", kind: "file", parent_node_id: "d-theirs",
                          mtime: 1, size: 1, content_hash: "h-theirs", current_version_id: "v-theirs")
      other.nodes.create!(node_id: "d-dead", name: "dead", kind: "dir", mtime: 1, size: 0)
      get tools_addon_path("destkit")
      assert_default "d-live", "/live"
    end

    # THE ROOT IS AN ANSWER, NOT A MISS: a newest output at the root must not fall through to an older
    # output's folder. This is the LEFT JOIN in #latest_output_folder — an INNER join drops the root
    # output's row, and the older output becomes the newest one left.
    test "a newest output at the library root keeps the tool at the root" do
      dir("d-old", "old")
      file("n-old", "old.svg", "d-old")
      saved("n-old", at: 2.days.ago)
      file("n-root", "root.svg", nil)
      saved("n-root", at: 1.minute.ago)
      get tools_addon_path("destkit")
      assert_default "", "/ (library root)"
    end

    test "an output the intake sweep filed into a project's category folder starts at the project folder" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      dir("d-design", "design", folder.node_id)
      file("n-lamp", "lamp.svg", "d-design")
      saved("n-lamp", at: 1.minute.ago)
      get tools_addon_path("destkit")
      assert_default folder.node_id, "/Projects/desk-lamp"
    end

    test "only this tool's own outputs count" do
      dir("d-mine", "mine")
      dir("d-other", "other")
      file("n-mine", "mine.svg", "d-mine")
      saved("n-mine", at: 2.days.ago)
      file("n-other", "other.svg", "d-other")
      saved("n-other", at: 1.minute.ago, key: "someone-else")
      get tools_addon_path("destkit")
      assert_default "d-mine", "/mine"
    end

    # STEP 2 — a reopened file starts in ITS folder, even when another box is newer, and WITHOUT the
    # project mapping: a revision replaces its own output in place wherever that output lives.
    test "?state= starts where that state's own output lives" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      dir("d-design", "design", folder.node_id)
      dir("d-new", "new")
      file("n-lamp", "lamp.svg", "d-design")
      reopened = saved("n-lamp", at: 3.days.ago)
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      get tools_addon_path("destkit", state: reopened.id)
      assert_default "d-design", "/Projects/desk-lamp/design"
    end

    # STEP 2 READS THE STATE'S LATEST SAVE, NOT ITS OLDEST ROW. While the tiebreak answered, "Edit in
    # <tool>" on the current file started in the stale folder, and #resolve_placements' owned arm
    # then rewrote the OLD file there. The newer box elsewhere is what makes this step 2's answer:
    # were step 2 to answer nothing, step 3 would start the tool in `d-newer`.
    test "?state= starts where that state's LATEST save put its output" do
      reopened = revised_across_folders(at: 3.days.ago)
      dir("d-newer", "newer")
      file("n-newer", "newer.svg", "d-newer")
      saved("n-newer", at: 1.minute.ago)
      get tools_addon_path("destkit", state: reopened.id)
      assert_default "d-new", "/new"
    end

    # STEP 3, THE SAME QUESTION ONE STEP LATER: the newest box decides, and within it the latest save.
    test "with no ?state=, the newest box's latest save decides where the tool starts" do
      revised_across_folders(at: 1.minute.ago)
      get tools_addon_path("destkit")
      assert_default "d-new", "/new"
    end

    # WITHIN ONE SAVE, THE FILE IT LISTED FIRST DECIDES. Both rows carry the same revision and the
    # position-1 row is created FIRST, so `revision DESC, id` alone answers its folder; only
    # `position` in #latest_output_folder's ORDER BY answers the first-listed file's.
    test "within one save, the file it listed first decides where the tool starts" do
      dir("d-first", "first")
      dir("d-second", "second")
      file("n-second", "second.svg", "d-second")
      file("n-first", "first.svg", "d-first")
      state = @user.maker_addon_states.create!(addon_key: "destkit", name: "two-file box", data: {}, revision: 2)
      state.files.create!(node_id: "n-second", role: "output", position: 1, revision: 2)
      state.files.create!(node_id: "n-first", role: "output", position: 0, revision: 2)
      get tools_addon_path("destkit")
      assert_default "d-first", "/first"
    end

    # STEP 2'S ROOT IS AN ANSWER TOO, AND THIS IS THE ONE TEST THAT CAN SEE `empty?`-NOT-`any?` in
    # #destination_from_outputs. Step 3 cannot: its own `rows.first.nil?` answers nil for `[nil]`
    # either way, so the root test above stays green over `any?` (measured). Here `[nil].any?` is
    # false, the reopened box falls through to step 3, and it starts in a newer box's folder.
    test "?state= for a box saved at the library root starts at the root, not where a newer box went" do
      file("n-root", "root.svg", nil)
      reopened = saved("n-root", at: 3.days.ago)
      dir("d-new", "new")
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      get tools_addon_path("destkit", state: reopened.id)
      assert_default "", "/ (library root)"
    end

    test "a ?state= that resolves to nothing falls through to the newest output" do
      dir("d-new", "new")
      file("n-new", "new.svg", "d-new")
      saved("n-new", at: 1.minute.ago)
      get tools_addon_path("destkit", state: 999_999)
      assert_default "d-new", "/new"
    end

    # The ctx blob carries the same answer as the legacy attribute (addons.md: both shapes, one render).
    test "the ctx blob's defaultFolder agrees with the attribute" do
      dir("d-jigs", "jigs")
      get tools_addon_path("destkit", in: "d-jigs")
      ctx = JSON.parse(css_select("[data-controller='addon']").first["data-addon-ctx-value"])
      assert_equal({ "nodeId" => "d-jigs", "label" => "/jigs" }, ctx["defaultFolder"])
    end

    # THE SOURCE MUST READ AS CONFIGURED, OR THE MENU LISTS NOTHING AND BOTH ASSERTIONS FIND NO LINK.
    # Tools::HomeController#new_menu asks Source.configured?, which reads ENV alone — the stub decides
    # what Source.current answers, not whether a source exists. Any non-blank value will do while the
    # stub is in place, since the stub wins over it in Source.current.
    test "the New menu's tool links carry the folder they were opened from" do
      prior = ENV["ADDON_SOURCE_PATH"]
      ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s

      get tools_new_menu_path(in: "d-jigs")
      assert_select "turbo-frame#new-menu-tools a.menu-item[href=?]", tools_addon_path("destkit", in: "d-jigs")
      get "#{tools_new_menu_path}?in[]=x"
      assert_select "turbo-frame#new-menu-tools a.menu-item[href=?]", tools_addon_path("destkit")
    ensure
      prior ? ENV["ADDON_SOURCE_PATH"] = prior : ENV.delete("ADDON_SOURCE_PATH")
    end

    # THE TOP BAR'S UPLOAD STARTS WHERE THE SAVE STARTS (redesign slice 4, FolderDestination), so the
    # page never names two folders. QUIET: a tool page's primary is its own Save. A tool page always
    # HAS a destination — with nothing saved it is the root, named — so it never asks with the
    # chooser. Branches on the flow this leg renders, or the form arm is red on chunk_remote.
    test "the top bar's Upload saves where the tool's save starts, quietly" do
      dir("d-jigs", "jigs")
      { tools_addon_path("destkit", in: "d-jigs") => [ "d-jigs", "jigs" ],
        tools_addon_path("destkit") => [ "", "the library root" ] }.each do |path, (node_id, caption)|
        get path
        assert_response :success
        if FileLayer.current.capabilities.port_writable?
          assert_select "header.topbar .topbar-upload form.uploader input[name='parent_node_id'][value=?]", node_id
        else
          assert_select "header.topbar .topbar-upload section.uploader[data-uploader-parent-node-id-value=?]", node_id
        end
        assert_select "header.topbar .topbar-upload label.upload-btn:not(.primary)"
        assert_select "header.topbar .topbar-upload-caption", text: "Saves to #{caption}"
        assert_select "header.topbar .topbar-upload[data-controller]", 0
      end
    end
  end
end
