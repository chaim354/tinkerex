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

    test "a rejected value hands the EDITOR back with the user's own form still in it" do
      post tools_openscad_path, params: { generator: "hex_plate", name: "My plate",
                                          parent_node_id: "", params: { cols: "))(" } }
      assert_response :unprocessable_entity
      assert_select ".flash-alert", text: /cols/
      assert_select "input[name=?][value=?]", "name", "My plate"       # their name survived
      assert_select "input[name=?][value=?]", "params[cols]", "))("    # and the value to fix
      assert_equal 0, @user.maker_addon_states.for_addon("openscad").count, "nothing may be saved"
    end

    # --- both sources render the editor (Task 11) ---------------------------------------------

    test "the editor renders every field branch for a catalog generator" do
      get new_tools_openscad_path(generator: "hex_plate")
      assert_response :success
      assert_select "input[name=?][value=?]", "generator", "hex_plate"
      assert_select "input[type=number][name=?][value=?]", "params[cols]", "4"      # int
      assert_select "input[type=checkbox][name=?]", "params[rounded]"               # bool
      assert_select "input[type=text][name=?][value=?]", "params[span]", "10,20,30" # vector
      # An enum keeps VALUES and LABELS apart — the option's value is 1, its text is "solid".
      assert_select "select[name=?] option[value=?]", "params[mode]", "1", text: /solid/
      # The sidecar's "advanced" flag collapses that group instead of hiding it.
      assert_select "details.param-group-adv summary", text: "Advanced"
    end

    test "the editor renders for a bring-your-own library .scad" do
      node_id = seed_scad(@user, "part.scad")
      get new_tools_openscad_path(node_id:)
      assert_response :success
      assert_select "h1", text: "part.scad"
      assert_select "input[name=?][value=?]", "node_id", node_id
      assert_select "input[name=?]", "params[cols]" # schema derived from the file's own source
      assert_select "input[name=?]", "generator", count: 0
    end

    test "a node_id belonging to someone else is REFUSED by OUR guard, before the file layer" do
      other = User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      stranger_node = seed_scad(other, "secret.scad")

      get new_tools_openscad_path(node_id: stranger_node)
      assert_redirected_to tools_openscad_path

      post preview_tools_openscad_path, params: { node_id: stranger_node, params: { cols: "4" } }
      assert_response :unprocessable_entity
      assert_nil OpenscadClient.current.rendered, "a foreign node must never reach the render path"
      # ASSERT THE MECHANISM, NOT JUST THE OUTCOME. FileLayer#read is user-scoped too, so it refuses
      # a foreign node on its own — dropping `current_user` from own_scad_node_id! leaves every
      # assertion above GREEN (verified by mutation), and the test that was meant to pin the guard
      # would instead be pinning the layer underneath it. The message is what tells them apart: ours
      # names the library, the file layer's echoes the raw node id back.
      assert_equal "no such .scad in your library", response.body
    end

    private

    # A real .scad in a user's library, written through the SAME backend-neutral path the addon
    # itself uses — so this seeds correctly on chunk, share and s3 alike.
    def seed_scad(user, name)
      state = user.maker_addon_states.create!(addon_key: "fixture", name: "seed-#{SecureRandom.hex(3)}")
      Maker::Addons::LibraryOutput.write(
        user:, state:, parent_node_id: nil,
        files: [ { name:, bytes: "cols = 4;\ncube([cols, 1, 1]);\n".b,
                   content_type: "text/plain", role: "output" } ]
      ).first.node_id
    end
  end
end
