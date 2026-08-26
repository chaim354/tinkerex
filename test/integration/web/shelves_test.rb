require "test_helper"

module Web
  # Task 8: the shelves settings page. A shelf is stored as a PATH PATTERN, not a node id -- so the
  # page's job is (a) to turn a picked folder into a pattern, and (b) to say whether each stored
  # pattern currently names anything, which is what makes path-keying honest.
  #
  # NO BACKEND IS PINNED HERE, deliberately, unlike models_flow_test.rb and models_catalog_test.rb.
  # ShelvesController reads `nodes` and `maker_shelves` and calls the port not at all, and neither
  # does the layout it renders -- so there is nothing for FileLayer.current to answer and nothing
  # for the ambient LIBRARY_BACKEND to change. Adding use_fresh_share_library! here would pin a
  # backend this page never asks about.
  class ShelvesTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    setup do
      @user = User.create!(email: "sh-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_as(@user)
    end

    # DEVIATION FROM THE PLAN, the same one models_catalog_test.rb records: `sign_in_as` does not
    # exist in test_helper.rb. The only method by that name is a Capybara helper in
    # test/system/support/web_helpers.rb, which takes an EMAIL and drives the real form. This is a
    # plain ActionDispatch::IntegrationTest, so -- like every other web integration test here -- it
    # defines its own, taking the already-built @user the test bodies attach rows to.
    def sign_in_as(user)
      post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
    end

    test "the page seeds the three shelves on first visit" do
      get shelves_path

      assert_response :success
      assert_equal [ "", "Models", "Projects/*/models" ], @user.maker_shelves.order(:path).pluck(:path)
    end

    # THE FORM POSTS A FLAT `node_id` AND THE CONTROLLER READS `params[:node_id]`. Asserted on the
    # RENDERED FIELD NAME rather than assumed: §14d records two shipped bugs where a `form_with`
    # emitted param names the controller's `require` rejected, both invisible to tests that POSTed
    # a Ruby hash -- which is exactly what every POST below does.
    test "the add form posts the flat node_id the controller reads" do
      get shelves_path

      assert_select "form.shelf-add input[type=hidden][name=?]", "node_id"
    end

    # TWO MATCHING FOLDERS, NOT THE PLAN'S ONE, AND THAT IS THE WHOLE POINT OF THE ROW. "how many"
    # is the claim; with a single match the assertion cannot tell a COUNT from a PRESENCE FLAG --
    # `hits = matches.any? ? 1 : 0` renders "1 folder matched" and stays green, which would report
    # "1 folder" to a user whose wildcard covers twelve. Mutation-checked both ways.
    test "a wildcard row renders and reports how many folders it matches" do
      @user.nodes.create!(node_id: "d-p", name: "Projects", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-l", name: "lamp", kind: "dir", parent_node_id: "d-p", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-m", name: "models", kind: "dir", parent_node_id: "d-l", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-d", name: "desk", kind: "dir", parent_node_id: "d-p", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-n", name: "models", kind: "dir", parent_node_id: "d-d", mtime: 1, size: 0)
      # A NEAR MISS that must NOT be counted: `*` matches exactly one segment, never two, so
      # Projects/desk/spare/models is not what Projects/*/models names.
      @user.nodes.create!(node_id: "d-s", name: "spare", kind: "dir", parent_node_id: "d-d", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-x", name: "models", kind: "dir", parent_node_id: "d-s", mtime: 1, size: 0)

      get shelves_path

      assert_response :success
      assert_select "li", text: /Projects\/\*\/models/
      assert_select ".shelf-status", text: /2 folders/
    end

    # THE INDICATOR IS WHAT MAKES PATH-KEYING HONEST. A path that resolves to nothing says so
    # instead of quietly cataloguing nothing.
    test "a path with no live folder is reported as missing" do
      @user.maker_shelves.create!(path: "Nowhere")
      @user.update_column(:shelves_seeded_at, Time.current)

      get shelves_path

      assert_select ".shelf-status", text: /no folder at this path/i
    end

    # THE CHOOSER RETURNS A node_id; THE CONTROLLER DERIVES THE PATH. A picker cannot produce a
    # path string, and deriving it server-side is the only place the two can be kept in step.
    test "adding a shelf converts the chosen node into a path" do
      @user.nodes.create!(node_id: "d-a", name: "3D Models", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-b", name: "Prints", kind: "dir", parent_node_id: "d-a", mtime: 1, size: 0)

      post shelves_path, params: { node_id: "d-b" }

      assert_redirected_to shelves_path
      assert_includes @user.maker_shelves.pluck(:path), "3D Models/Prints"
    end

    test "adding the library root stores the empty path" do
      @user.update_column(:shelves_seeded_at, Time.current)
      post shelves_path, params: { node_id: "" }

      assert_includes @user.maker_shelves.pluck(:path), ""
    end

    test "adding a duplicate is refused with a message, not a 500" do
      @user.maker_shelves.create!(path: "Models")
      @user.update_column(:shelves_seeded_at, Time.current)
      @user.nodes.create!(node_id: "d-m", name: "Models", kind: "dir", mtime: 1, size: 0)

      post shelves_path, params: { node_id: "d-m" }

      assert_redirected_to shelves_path
      assert_match(/already/i, flash[:alert])
      assert_equal 1, @user.maker_shelves.count
    end

    # A PICKER CAN REACH THE RESERVED-NAME REFUSAL. A library with a real `.trash` directory offers
    # that folder like any other, so the refusal has to say what is actually wrong rather than
    # falling through to the duplicate message.
    test "picking a reserved folder is refused with its own message" do
      @user.update_column(:shelves_seeded_at, Time.current)
      @user.nodes.create!(node_id: "d-trash", name: ".trash", kind: "dir", mtime: 1, size: 0)

      post shelves_path, params: { node_id: "d-trash" }

      assert_empty @user.maker_shelves
      assert_match(/can't be a folder name/i, flash[:alert])
      assert_no_match(/already/i, flash[:alert])
    end

    # DEVIATION FROM THE PLAN'S ASSERTION, and it is the difference between a guard and a
    # decoration. The plan asserted `maker_shelves.where.not(path: "")` -- which stays green even
    # if the derivation answers "" (the LIBRARY ROOT) for a folder that isn't the user's, because
    # `where.not(path: "")` is exactly the filter that hides that row. Nothing is expected to exist
    # here at all, so assert that: mutating `return nil unless node` to `return ""` then turns this
    # red instead of passing over a shelf it just created. The flash is asserted for the same
    # reason -- a refusal must reach the user as a refusal.
    test "another user's node cannot be turned into a shelf" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      other.nodes.create!(node_id: "d-theirs", name: "Theirs", kind: "dir", mtime: 1, size: 0)
      @user.update_column(:shelves_seeded_at, Time.current)

      post shelves_path, params: { node_id: "d-theirs" }

      assert_empty @user.maker_shelves
      assert_match(/isn't in your library/i, flash[:alert])
    end

    test "removing a shelf removes it" do
      get shelves_path
      shelf = @user.maker_shelves.find_by!(path: "Models")

      delete shelf_path(shelf)

      assert_redirected_to shelves_path
      assert_nil Maker::Shelf.find_by(id: shelf.id)
    end

    test "another user's shelf cannot be removed" do
      other = User.create!(email: "o2-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.maker_shelves.create!(path: "Models")

      delete shelf_path(theirs)

      assert_response :not_found
      assert_predicate Maker::Shelf.find_by(id: theirs.id), :present?
    end
  end
end
