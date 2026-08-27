require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  # Exercises the extracted concern through a tiny host that includes it, so the behavior is pinned
  # independently of any one addon. Uses the same "scope to the user's own live dirs" contract the
  # boxes folder tests already rely on.
  class LibraryFoldersTest < ActiveSupport::TestCase
    class Host
      include Tools::LibraryFolders
      attr_reader :current_user, :params
      def initialize(user, params) = (@current_user, @params = user, ActionController::Parameters.new(params))
    end

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "lf@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    def dir(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent)
    end

    test "folder_options lists the library root first, then the user's folders by path" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      opts = Host.new(@user, {}).send(:folder_options)
      assert_equal [ "/ (library root)", "" ], opts.first
      assert opts.any? { |label, _| label == "/Projects" }
    end

    test "chosen_parent_node_id returns nil for a blank param (root)" do
      assert_nil Host.new(@user, {}).send(:chosen_parent_node_id)
    end

    test "chosen_parent_node_id returns the node_id of the user's own live folder" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      host = Host.new(@user, { parent_node_id: dir.node_id })
      assert_equal dir.node_id, host.send(:chosen_parent_node_id)
    end

    test "chosen_parent_node_id ignores a folder that is not the user's own (falls back to root)" do
      other = User.create!(email: "lf-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      host = Host.new(@user, { parent_node_id: foreign.node_id })
      assert_nil host.send(:chosen_parent_node_id)
    end

    # --- folder_path_label, one case per answer it can give ----------------------
    #
    # CHARACTERISATION, WRITTEN BEFORE THE TWO DERIVATIONS WERE FOLDED INTO ONE. The whole basis of
    # sharing Maker::LibraryTree between folder_options and folder_path_label is that the two
    # already answer identically; that was argued and never pinned, so these are the pins. The
    # values are what the pre-share code produced, measured — a new format here is an out-of-repo
    # break (§14c: published bundles read `defaultFolderLabel` and Rails is never rebuilt with one).

    test "folder_path_label calls a blank id the library root" do
      host = Host.new(@user, {})
      assert_equal Tools::LibraryFolders::ROOT_LABEL, host.send(:folder_path_label, nil)
      assert_equal Tools::LibraryFolders::ROOT_LABEL, host.send(:folder_path_label, "")
    end

    test "folder_path_label builds a leading-slash path, one segment per ancestor" do
      dir("d-projects", "Projects")
      dir("d-harbor", "harbor", "d-projects")
      host = Host.new(@user, {})
      assert_equal "/Projects", host.send(:folder_path_label, "d-projects")
      assert_equal "/Projects/harbor", host.send(:folder_path_label, "d-harbor")
    end

    # NOT A FOLDER OF THIS USER'S AT ALL — root is the honest answer, and it is the same fallback
    # chosen_parent_node_id makes for the same three inputs.
    test "folder_path_label calls a foreign, file or unknown id the library root" do
      other = User.create!(email: "lf-other2@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      file = @user.nodes.create!(node_id: "n-file", name: "a.stl", kind: "file", mtime: 1, size: 1)
      host = Host.new(@user, {})
      assert_equal Tools::LibraryFolders::ROOT_LABEL, host.send(:folder_path_label, foreign.node_id)
      assert_equal Tools::LibraryFolders::ROOT_LABEL, host.send(:folder_path_label, file.node_id)
      assert_equal Tools::LibraryFolders::ROOT_LABEL, host.send(:folder_path_label, "nope")
    end

    # A FOLDER WHOSE PARENT ROW IS GONE IS STILL A FOLDER, AND MUST NOT BE LABELLED "/ (library
    # root)". That label under a real node id is the failure addon_bundle_test.rb's "wrong in the
    # direction that looks like it worked" comment exists to catch — the user saves into a folder
    # the trigger button told them was the root. The bare leaf is what the pre-share code gave.
    test "folder_path_label falls back to the bare leaf when an ancestor row is gone" do
      dir("d-gone", "Gone").update!(deleted: true)
      dir("d-charlie", "charlie", "d-gone")
      assert_equal "/charlie", Host.new(@user, {}).send(:folder_path_label, "d-charlie")
    end

    # THE EQUIVALENCE THE SHARED INDEX RELIES ON, asserted id-for-id rather than argued. Both
    # derivations are fed the same rows, including the broken-chain one above.
    test "folder_options and folder_path_label agree on every folder" do
      dir("d-projects", "Projects")
      dir("d-harbor", "harbor", "d-projects")
      dir("d-gone", "Gone").update!(deleted: true)
      dir("d-charlie", "charlie", "d-gone")
      host = Host.new(@user, {})
      options = host.send(:folder_options).reject { |_label, id| id.blank? }

      assert_equal 3, options.size
      options.each do |label, id|
        assert_equal label, host.send(:folder_path_label, id),
                     "the picker and the trigger button disagree about #{id}"
      end
    end

    # --- the parent cycle -------------------------------------------------------
    #
    # RED BEFORE THE SHARED INDEX LANDED: folder_options' memo wrote its entry AFTER recursing, so
    # a two-node cycle recursed until the stack gave out — SystemStackError, which is a 500 on
    # /tools/:addon (see the request test below). folder_path_label had its own `seen` Set and
    # answered a partial path, so the same rows produced three different answers in three places.
    # Maker::LibraryTree owns the guard now and answers nil; this surface maps that to the bare leaf.

    test "folder_options survives a parent cycle instead of blowing the stack" do
      dir("d-a", "alpha", "d-b")
      dir("d-b", "bravo", "d-a")
      labels = Host.new(@user, {}).send(:folder_options).to_h { |label, id| [ id, label ] }
      assert_equal "/alpha", labels["d-a"]
      assert_equal "/bravo", labels["d-b"]
    end

    test "folder_path_label survives a parent cycle and agrees with the picker" do
      dir("d-a", "alpha", "d-b")
      dir("d-b", "bravo", "d-a")
      host = Host.new(@user, {})
      assert_equal "/alpha", host.send(:folder_path_label, "d-a")
      assert_equal host.send(:folder_options).to_h { |l, i| [ i, l ] }["d-a"],
                   host.send(:folder_path_label, "d-a")
    end

    # --- query cost -------------------------------------------------------------

    # CONSTANT IN DEPTH, NEVER A LITERAL (§14e): the absolute count differs per LIBRARY_BACKEND, so
    # a number pins one leg and fails the other two. This measures exactly the pair
    # Tools::AddonsController#show runs on one render (folder_options, then folder_path_label).
    # Before the shared index the label cost one find_by per hop: 1 + depth against 1 + 0.
    test "the picker and the trigger button together cost the same at depth 2 and depth 8" do
      chain = ->(prefix, depth) do
        parent = nil
        depth.times { |i| parent = dir("#{prefix}-#{i}", "#{prefix}#{i}", parent).node_id }
        parent
      end
      shallow = chain.call("s", 2)
      deep    = chain.call("d", 8)

      shallow_cost = count_queries { pair(shallow) }
      deep_cost    = count_queries { pair(deep) }
      assert_equal shallow_cost, deep_cost,
                   "the addon page's folder queries grow with how deep the chosen folder is"
    end

    def pair(node_id)
      host = Host.new(@user, {})
      host.send(:folder_options)
      host.send(:folder_path_label, node_id)
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end

  # THE DEFECT AT THE DOOR, NOT IN A HELPER. A SystemStackError out of folder_options is a 500 on
  # every addon page for a user whose library holds a parent cycle — and the chunk_remote mirror is
  # a row set, where a cycle is perfectly representable (§14k). A unit test on the concern proves
  # the helper; only a request proves the page.
  class LibraryFoldersRequestTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # No `services`, so nothing here depends on a sidecar URL being configured.
    MANIFEST = {
      "key" => "folderkit", "title" => "Folder Kit", "icon" => "📁",
      "description" => "Pins the save-folder picker", "api_version" => "1",
      "entry" => "folderkit.js"
    }.freeze

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST ], assets: { "folderkit/folderkit.js" => "export default {}" }
      )
      # Per-test email for the chunk_remote leg's non-transactional sync database — the reason
      # addons_controller_test.rb spells out at its own setup.
      @user = User.create!(email: "lf-req-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      Maker::Addons::Source.reset!
      Rails.cache = @prior_cache
    end

    test "an addon page renders for a library whose parent chain loops" do
      @user.nodes.create!(node_id: "d-a", name: "alpha", kind: "dir", parent_node_id: "d-b")
      @user.nodes.create!(node_id: "d-b", name: "bravo", kind: "dir", parent_node_id: "d-a")

      get tools_addon_path(MANIFEST["key"])
      assert_response :success
      folders = JSON.parse(css_select("[data-controller=addon]").first["data-addon-folders-value"])
      assert_includes folders, [ "/alpha", "d-a" ]
    end
  end
end
