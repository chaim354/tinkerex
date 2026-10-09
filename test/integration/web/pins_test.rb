require "test_helper"

module Web
  class PinsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pins-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
    end

    test "a folder's ⋯ menu offers Pin, and pinning lands back in the folder" do
      get files_path(folder: @dir.node_id)
      assert_select "details.menu form[action=?] input[name='node_id'][value=?]", pins_path, @dir.node_id
      assert_select "details.menu button", text: "Pin to sidebar"

      post pins_path, params: { node_id: @dir.node_id }
      assert_redirected_to files_path(folder: @dir.node_id)
      assert_equal [ @dir.node_id ], @user.maker_pins.pluck(:node_id)

      follow_redirect!
      assert_select "details.menu button", text: "Unpin from sidebar"
    end

    test "unpinning removes the pin and lands back in the folder" do
      @user.maker_pins.create!(node_id: @dir.node_id)
      delete pin_path(@dir.node_id)
      assert_redirected_to files_path(folder: @dir.node_id)
      # `.reload`: the `create!` above left the pin in the association's in-memory target, which
      # `empty?` reads before it asks the database.
      assert_empty @user.maker_pins.reload
    end

    test "the library root offers no pin" do
      get files_path
      assert_select "details.menu button", text: "Pin to sidebar", count: 0
    end

    test "a refused pin says why and creates nothing" do
      file = @user.nodes.create!(node_id: "file-a", name: "a.stl", kind: "file")
      post pins_path, params: { node_id: file.node_id }, headers: { "HTTP_REFERER" => files_url }
      assert_redirected_to files_url
      assert_equal "That folder isn't in your library.", flash[:alert]
      assert_empty @user.maker_pins
    end

    # THE RACE, FORCED: a double-clicked Pin sends two requests that both pass the uniqueness check;
    # the second insert hits the unique index. `save` raising RecordNotUnique is that second insert.
    test "a double-clicked Pin lands like a single one instead of failing" do
      Maker::Pin.class_eval do
        alias_method :__real_save, :save
        define_method(:save) { |*| raise ActiveRecord::RecordNotUnique, "duplicate pin" }
      end
      post pins_path, params: { node_id: @dir.node_id }
      assert_redirected_to files_path(folder: @dir.node_id)
      assert_equal "Pinned to the sidebar.", flash[:notice]
    ensure
      Maker::Pin.class_eval do
        alias_method :save, :__real_save
        remove_method :__real_save
      end
    end

    test "another user's pin cannot be removed" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      theirs = other.nodes.create!(node_id: "dir-theirs", name: "theirs", kind: "dir")
      other.maker_pins.create!(node_id: theirs.node_id)
      delete pin_path(theirs.node_id)
      assert_response :not_found
      assert_equal 1, other.maker_pins.count
    end
  end
end
