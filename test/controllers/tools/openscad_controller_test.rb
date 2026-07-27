require "test_helper"
require_relative "../../support/fake_openscad"

module Tools
  class OpenscadControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "oscad@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # The gallery GREYS OUT an addon whose sidecar isn't configured, so a test that asserts the
      # LINK renders has to look like a deployment that has one. The stub still answers every call:
      # OpenscadClient.current prefers @stub over the URL, so nothing here reaches the network.
      @prior_sidecar_url = ENV["OPENSCAD_SIDECAR_URL"]
      ENV["OPENSCAD_SIDECAR_URL"] = "http://openscad.invalid"
      OpenscadClient.stub = FakeOpenscad.new
      Storage::ChunkStore.reset!
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end
    teardown do
      ENV["OPENSCAD_SIDECAR_URL"] = @prior_sidecar_url
      OpenscadClient.reset!
      FileLayer.reset!
    end

    test "the /tools gallery links the addon without raising on the helper" do
      # REGRESSION GUARD: `resources :openscad` would make tools_openscad_path the SHOW helper, which
      # needs an id — and the gallery calls send("tools_#{key}_path") with no args, so /tools itself
      # would 500 for every user the moment this addon is registered.
      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", "/tools/openscad"
    end

    test "index lists the bundled catalog" do
      get tools_openscad_path
      assert_response :success
      assert_select ".addon-card .addon-title", text: "hex_plate"
    end

    # --- parameter coercion (Task 10) ---------------------------------------------------------
    # The full controller suite is Task 12; these three exist because the coercion is a DESIGN
    # DECISION made here, and an undefended one would quietly rot back into a pass-through.

    test "preview coerces every submitted value to its declared type before rendering" do
      post preview_tools_openscad_path, params: {
        generator: "hex_plate",
        params: { cols: "6", wall: "2.5", rounded: "true", label: "hi", span: "10, 20,30", mode: "2" }
      }
      # The PNG step shells out to the stl-thumbnailer binary, so a box without it answers 422 by
      # design (PreviewUnavailable, not a coercion refusal). What this test is about is what reached
      # the SIDECAR, which is identical either way.
      assert_response(Maker::Previews::Stl.available? ? :success : :unprocessable_entity)
      assert_equal({ "cols" => 6, "wall" => 2.5, "rounded" => true, "label" => "hi",
                     "span" => "[10,20,30]", "mode" => 2 },
                   OpenscadClient.current.rendered[:params])
    end

    test "a value that will not coerce is REFUSED, not handed to OpenSCAD to ignore" do
      # THE WHOLE POINT (observed against the real sidecar): OpenSCAD's parameterSet silently
      # ignores a value it cannot parse and renders the DEFAULT geometry — so a pass-through gives a
      # typo a 200 and a wrong model, saved to the library, with no feedback anywhere.
      # An ARRAY of pairs, not a Hash: two of these probe the same field, and a Hash literal would
      # keep only the last one — dropping a case while staying green.
      [
        [ "cols",    "))(" ],   # the observed real case
        [ "cols",    "4.5" ],   # an int field, non-integral
        [ "wall",    "" ],      # a cleared number field: the default is NOT what they asked for
        [ "rounded", "maybe" ], # not a boolean, and must not become `true` by falling through
        [ "span",    "10,,30" ], # a hole in the vector
        [ "mode",    "3" ]      # not one of the declared choices
      ].each do |name, bad|
        OpenscadClient.stub = FakeOpenscad.new # a fresh recorder per case
        post preview_tools_openscad_path, params: { generator: "hex_plate", params: { name => bad } }
        assert_response :unprocessable_entity, "#{name}=#{bad.inspect} should be refused"
        assert_match(/#{name}/, response.body, "the message should name the parameter")
        assert_nil OpenscadClient.current.rendered, "#{name}=#{bad.inspect} must never reach the sidecar"
      end
    end

    test "a parameter the design doesn't declare is refused, not silently dropped" do
      post preview_tools_openscad_path, params: { generator: "hex_plate", params: { colz: "9" } }
      assert_response :unprocessable_entity
      assert_match(/colz/, response.body)
      assert_nil OpenscadClient.current.rendered
    end
  end
end
