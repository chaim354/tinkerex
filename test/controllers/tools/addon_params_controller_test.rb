require "test_helper"

module Tools
  # The params behind any addon state, as a download. This replaces the `.params.json` file that
  # every addon used to write into the library beside its output (removed 2026-07-29: nothing ever
  # read it back, and `Maker::AddonState#data` is the record).
  class AddonParamsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "addonparams@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @state = @user.maker_addon_states.create!(
        addon_key: "boxes", name: "My Box",
        data: { "generator" => "ABox", "params" => { "x" => "120", "y" => "60" } }
      )
    end

    test "serves the whole data hash as pretty JSON, dispositioned as a download" do
      get tools_addon_params_path(@state)
      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal JSON.pretty_generate(@state.data), response.body
      assert_match(/\A\{\n/, response.body, "must be pretty-printed, not compact")
      assert_match "attachment", response.headers["Content-Disposition"]
      assert_match "my-box-#{@state.id}.params.json", response.headers["Content-Disposition"]
    end

    test "the download carries the generator, not only the params" do
      # `generator` is what made the removed file self-describing — with it you can tell what
      # produced the output sitting next to it. Params alone are an anonymous bag of numbers.
      get tools_addon_params_path(@state)
      body = JSON.parse(response.body)
      assert_equal "ABox", body["generator"]
      assert_equal({ "x" => "120", "y" => "60" }, body["params"])
    end

    test "another user's state is a 404, not a 403 and not a leak" do
      other = User.create!(email: "addonparams-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "boxes", name: "Theirs",
                                                data: { "generator" => "ABox", "params" => {} })
      get tools_addon_params_path(theirs)
      assert_response :not_found
    end

    test "requires login" do
      reset!
      get tools_addon_params_path(@state)
      assert_redirected_to new_user_session_path
    end

    test "a name that parameterizes to nothing falls back to the addon key" do
      # `"🎁".parameterize` is "" — the naive filename would be "-12.params.json".
      state = @user.maker_addon_states.create!(addon_key: "boxes", name: "🎁", data: {})
      get tools_addon_params_path(state)
      assert_response :success
      assert_match "boxes-#{state.id}.params.json", response.headers["Content-Disposition"]
    end

    test "serves any addon's state, not just boxes" do
      state = @user.maker_addon_states.create!(
        addon_key: "openscad", name: "Hex Plate",
        data: { "generator" => "hex_plate", "node_id" => "n-1", "params" => { "cols" => 6 } }
      )
      get tools_addon_params_path(state)
      assert_response :success
      assert_equal 6, JSON.parse(response.body)["params"]["cols"], "the coerced Integer must survive"
    end
  end
end
