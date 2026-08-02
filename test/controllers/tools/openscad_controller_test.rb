require "test_helper"
require "zip"
require_relative "../../support/fake_openscad"

module Tools
  class OpenscadControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    # The exact bytes `seed_scad` puts in the library, so the bring-your-own tests can assert that
    # what reached the sidecar is the user's OWN file and not a catalog fallback.
    SCAD_FIXTURE = "cols = 4;\ncube([cols, 1, 1]);\n".freeze

    setup do
      @user = User.create!(email: "oscad@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # The gallery GREYS OUT an addon whose sidecar isn't configured, so a test that asserts the
      # LINK renders has to look like a deployment that has one. The stub still answers every call:
      # Tools::OpenscadClient.current prefers @stub over the URL, so nothing here reaches the network.
      @prior_sidecar_url = ENV["OPENSCAD_SIDECAR_URL"]
      ENV["OPENSCAD_SIDECAR_URL"] = "http://openscad.invalid"
      Tools::OpenscadClient.stub = FakeOpenscad.new
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
      Tools::OpenscadClient.reset!
      FileLayer.reset!
    end

    test "the /tools gallery links the addon without raising on the helper" do
      # REGRESSION GUARD: `resources :openscad` would make tools_openscad_path the SHOW helper, which
      # needs an id — and this addon registers that helper as its `path:` proc, so /tools itself would
      # 500 for every user. The generic version of this guard, covering every registered addon
      # including gem-supplied ones, is in test/services/maker/addons/registry_test.rb.
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
                   Tools::OpenscadClient.current.rendered[:params])
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
        Tools::OpenscadClient.stub = FakeOpenscad.new # a fresh recorder per case
        post preview_tools_openscad_path, params: { generator: "hex_plate", params: { name => bad } }
        assert_response :unprocessable_entity, "#{name}=#{bad.inspect} should be refused"
        assert_match(/#{name}/, response.body, "the message should name the parameter")
        assert_nil Tools::OpenscadClient.current.rendered, "#{name}=#{bad.inspect} must never reach the sidecar"
      end
    end

    test "a parameter the design doesn't declare is refused, not silently dropped" do
      post preview_tools_openscad_path, params: { generator: "hex_plate", params: { colz: "9" } }
      assert_response :unprocessable_entity
      assert_match(/colz/, response.body)
      assert_nil Tools::OpenscadClient.current.rendered
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
      assert_equal "Couldn't read that generator: no such .scad in your library", flash[:alert]

      post preview_tools_openscad_path, params: { node_id: stranger_node, params: { cols: "4" } }
      assert_response :unprocessable_entity
      assert_nil Tools::OpenscadClient.current.rendered, "a foreign node must never reach the render path"
      # ASSERT THE MECHANISM, NOT JUST THE OUTCOME. FileLayer#read is user-scoped too, so it refuses
      # a foreign node on its own — dropping `current_user` from own_scad_node_id! leaves every
      # assertion above GREEN (verified by mutation), and the test that was meant to pin the guard
      # would instead be pinning the layer underneath it. The message is what tells them apart: ours
      # names the library, the file layer's echoes the raw node id back.
      assert_equal "no such .scad in your library", response.body
    end

    test "create refuses a foreign node_id rather than rendering it" do
      stranger_node = seed_scad(another_user, "os-stranger.scad")
      assert_no_difference [ "Maker::AddonState.count", "Maker::AddonFile.count" ] do
        post tools_openscad_path, params: { name: "OS Nope", node_id: stranger_node }
      end
      assert_redirected_to tools_openscad_path
      assert_nil Tools::OpenscadClient.current.rendered, "a foreign node must never reach the render path"
      # OUR guard's message again, for the same reason as the test above: the redirect alone stays
      # green with `current_user` dropped from own_scad_node_id!, because FileLayer#read refuses a
      # foreign node downstream anyway.
      assert_equal "Generation failed: no such .scad in your library", flash[:alert]
    end

    # --- what the index offers (Task 12) -------------------------------------------------------

    test "index lists the user's own .scad — only .scad, and only the user's own" do
      mine     = seed_scad(@user, "os-bracket.scad")
      not_scad = seed_scad(@user, "os-notes.txt")
      theirs   = seed_scad(another_user, "os-theirs.scad")

      get tools_openscad_path
      assert_response :success
      assert_select "a[href=?]", new_tools_openscad_path(node_id: mine)
      # BOTH negatives are the point. `library_scad_files` filters on the extension AND the owner,
      # and with a single-file fixture a missing filter of either kind is invisible.
      assert_select "a[href=?]", new_tools_openscad_path(node_id: not_scad), count: 0
      assert_select "a[href=?]", new_tools_openscad_path(node_id: theirs), count: 0
    end

    test "index shows each bundled generator's licence on its OWN tile" do
      # These are third-party designs; the attribution terms travel with whatever the user makes.
      # Matched per-tile rather than "MIT appears somewhere", so swapping two licences is caught.
      get tools_openscad_path
      assert_response :success
      assert_select ".addon-card", text: /hex_plate.*\bMIT\b/m
      assert_select ".addon-card", text: /divider_tray.*BSD-3-Clause/m
    end

    test "an unknown generator redirects instead of 500ing" do
      get new_tools_openscad_path(generator: "no-such-generator")
      assert_redirected_to tools_openscad_path
      assert_equal "Unknown generator.", flash[:alert]
    end

    # --- the editor's form (Task 11) -----------------------------------------------------------

    test "the editor groups fields: open fieldsets for basics, collapsed details for advanced" do
      get new_tools_openscad_path(generator: "hex_plate")
      assert_response :success
      assert_select "fieldset.param-group > legend", text: "Grid"
      assert_select "fieldset.param-group input[name=?]", "params[cols]"
      assert_select "details.param-group-adv > summary", text: "Advanced"
      # An advanced field stays IN THE DOM (collapsed, not omitted) or it would never be submitted,
      # and OpenSCAD would silently render the default for it.
      assert_select "details.param-group-adv select[name=?]", "params[mode]"
    end

    test "an enum renders its LABELS while submitting its VALUES" do
      # OpenSCAD's `// [1:solid, 2:hollow]` gives a NUMERIC value a human label. Posting the label
      # back is a type error, which parameterSet ignores -> default geometry, silently.
      get new_tools_openscad_path(generator: "hex_plate")
      assert_response :success
      assert_select "select[name='params[mode]'] option[value='1']", text: /solid/
      # The converse is the half that catches conflating the two: a LABEL must never be submittable.
      assert_select "select[name='params[mode]'] option[value='solid']", count: 0
    end

    # --- render / preview ----------------------------------------------------------------------

    test "preview rasterizes the rendered 3MF server-side, and says so when it cannot" do
      post preview_tools_openscad_path, params: { generator: "hex_plate", params: { cols: "6" } }
      if Maker::Previews::Stl.available?
        assert_response :success
        assert_includes %w[image/png image/jpeg], response.media_type
        assert response.body.bytesize.positive?
      else
        # A sidecar 3MF carries no embedded slicer thumbnail, so ThreeMf ALWAYS falls through to its
        # mesh path, which shells out to `stl-thumbnailer` — absent on this box. That is a DEPLOYMENT
        # condition and the user is owed a sentence, not the Errno::ENOENT 500 it would otherwise be.
        assert_response :unprocessable_entity
        assert_match(/no preview image could be made/, response.body)
      end
      # True on either branch, and the half that is about THIS addon: the model itself rendered,
      # from the catalog source, as a 3MF, with the coerced value.
      assert_equal "3mf", Tools::OpenscadClient.current.rendered[:format]
      assert_equal FakeOpenscad.new.source("hex_plate"), Tools::OpenscadClient.current.rendered[:scad]
      assert_equal 6, Tools::OpenscadClient.current.rendered[:params]["cols"]
    end

    test "preview of a library file renders the user's OWN bytes, not the catalog's" do
      node_id = seed_scad(@user, "os-mine.scad")
      post preview_tools_openscad_path, params: { node_id:, params: { cols: "4" } }
      assert_response(Maker::Previews::Stl.available? ? :success : :unprocessable_entity)
      # ONE RENDER PATH (spec §3.1): both sources resolve to TEXT, and this pins that the BYO branch
      # resolves to the bytes actually in the library — read back through whichever FileLayer
      # backend this leg runs, which is what makes it mean something on share and s3 too.
      assert_equal SCAD_FIXTURE, Tools::OpenscadClient.current.rendered[:scad]
      refute_equal FakeOpenscad.new.source("hex_plate"), Tools::OpenscadClient.current.rendered[:scad]
    end

    test "a sidecar error is a 422 on preview and an alert on create — never a 500, never a half-save" do
      Tools::OpenscadClient.stub = Class.new(FakeOpenscad) do
        def render(**) = raise(Tools::OpenscadClient::Error, "Parser error: syntax error in line 3")
      end.new

      post preview_tools_openscad_path, params: { generator: "hex_plate", params: { cols: "4" } }
      assert_response :unprocessable_entity
      assert_match "Parser error", response.body # the sidecar's own words: the only actionable part

      # On create the state is built AFTER the render, and this is why: a failed render must not
      # leave a saved design sitting in the library with an empty bundle behind it.
      assert_no_difference [ "Maker::AddonState.count", "Maker::AddonFile.count" ] do
        post tools_openscad_path, params: { name: "OS Broken", generator: "hex_plate",
                                            params: { cols: "4" } }
      end
      assert_redirected_to tools_openscad_path
      assert_match "Parser error", flash[:alert]
    end

    # --- create: the bundle actually lands ------------------------------------------------------

    # THE TEST SPEC §11 SINGLES OUT, and the one CLAUDE.md's Phase 4 lesson says is easiest to fake:
    # it asserts the ONE AddonFile with its role, a REAL node in the library, and the BYTES read
    # back through FileLayer and confirmed to be a zip/OPC container — not merely that the
    # controller redirected. Reading through FileLayer is also what makes it meaningful on share and
    # s3 rather than only on chunk.
    test "create writes a real 3mf into the library, and the params stay in the DB" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_openscad_path, params: { name: "OS Bundle", generator: "hex_plate",
                                            params: { cols: "6", wall: "2.5" } }
      end
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last

      assert_equal %w[output], state.files.map(&:role)
      assert_equal [ "model/3mf" ], state.files.map(&:content_type)

      # A real library node, not just a join row.
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id), "no node for #{af.role}" }

      out = state.files.find { |f| f.role == "output" }
      assert @user.nodes.find_by(node_id: out.node_id).name.end_with?(".3mf")

      bytes = FileLayer.current.read(@user, node_id: out.node_id)
      assert_equal "PK", bytes[0, 2], "output is not a zip/OPC container"
      assert_equal FakeOpenscad.minimal_3mf.bytesize, bytes.bytesize,
                   "the bytes that landed are not the ones the sidecar rendered"
      entries = nil
      Zip::File.open_buffer(bytes.b) { |z| entries = z.map(&:name) }
      assert_includes entries, "3D/3dmodel.model", "not a 3MF: no OPC model part inside the zip"

      # NO params file. Asserted at the library level, not just on the join rows.
      assert_empty @user.nodes.present.where("name LIKE ?", "%.params.json"),
                   "no .params.json may be written into the library"

      # The DB records what was rendered — COERCED, so the design reproduces exactly. This assertion
      # used to read the params FILE; it MOVED to `data` rather than being deleted, because the
      # coercion it pins (a form String becoming an Integer/Float) is the reason Tools::OpenscadParams
      # exists, and `data` is now the only place it is recorded.
      assert_equal "hex_plate", state.data["generator"]
      assert_equal 6, state.data["params"]["cols"], "cols should be the coerced Integer, not the string"
      assert_equal 2.5, state.data["params"]["wall"]

      assert_redirected_to tools_openscad_design_path(state)
    end

    test "create does NOT copy the .scad source into the library" do
      # Spec §6.1: for a bring-your-own file, copying the source would spread a possibly
      # restrictively-licensed design around the user's library and into any future share/export
      # path. It is REFERENCED by node_id instead, which is all `show` and the prefill need.
      node_id = seed_scad(@user, "os-private.scad")
      scad_count = -> { @user.nodes.present.where("LOWER(name) LIKE ?", "%.scad").count }
      before = scad_count.call

      post tools_openscad_path, params: { name: "OS From Mine", node_id:, params: { cols: "4" } }
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last

      names = @user.nodes.where(node_id: state.files.map(&:node_id)).pluck(:name)
      assert_empty names.grep(/\.scad\z/i), "the .scad source must not be in the bundle"
      # …and not loose in the library either — the bundle check alone still passes if create writes
      # the source as an untied node.
      assert_equal before, scad_count.call, "no new .scad may appear in the library"
      assert_equal node_id, state.data["node_id"], "the source should be referenced, not copied"
    end

    # Spy on LibraryOutput.write (define_singleton_method — the repo's mocking idiom) so this
    # asserts the CONTROLLER's parent-selection wiring without depending on any one backend's write
    # mechanics: it passes identically on chunk/share/s3.
    test "create saves the bundle into the chosen folder" do
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_openscad_path, params: { name: "OS Placed", generator: "hex_plate",
                                            params: { cols: "4" }, parent_node_id: folder.node_id }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_equal folder.node_id, captured
    end

    test "create attaches the output file to the current project" do
      project = @user.maker_projects.create!(name: "OpenSCAD Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 1 do
        post tools_openscad_path, params: { name: "OS Attached", generator: "hex_plate",
                                            params: { cols: "4" }, parent_node_id: folder.node_id }
      end
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      assert_equal state.files.map(&:node_id).sort, project.file_attachments.pluck(:node_id).sort,
                   "the one bundle file (3mf) must be the attached node"
    end

    # --- show + the prefill link ----------------------------------------------------------------

    test "show reopens a saved design and its duplicate link actually prefills the editor" do
      post tools_openscad_path, params: { name: "OS Reopen", generator: "hex_plate",
                                          params: { cols: "9" } }
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      get tools_openscad_design_path(state)
      assert_response :success
      assert_select "*", text: /OS Reopen/
      assert_select ".bundle-files li", 1 # the tied bundle is what `show` is for — now just the output

      # WIRE FORMAT, asserted deliberately: params must be NESTED (params[cols]=9), not flattened.
      # `:params` is a reserved url_for option that appends its hash to the query string, so the
      # flat form is silently ignored by #new and nothing prefills. This exact bug shipped in the
      # Boxes addon once; comparing against the helper on both sides reproduces it and passes.
      href = css_select("a").filter_map { |a| a["href"] }.find { |h| h.include?("params%5B") }
      assert href, "expected a prefill link with nested params"
      assert_includes href, "params%5Bcols%5D=9"

      # END TO END: following it prefills the field, which is the behaviour that actually broke.
      get href
      assert_response :success
      assert_select "input[name='params[cols]'][value=?]", "9"
    end

    test "show lists the params and offers the JSON download" do
      # POSTed rather than hand-built: `show` resolves the source through `openscad_source_key`, and
      # a real save is the honest way to get a state that helper can read.
      post tools_openscad_path, params: { name: "OS Params", generator: "hex_plate",
                                          params: { cols: "6", wall: "2.5" } }
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      get tools_openscad_design_path(state)
      assert_response :success
      assert_select "section.addon-params dl.meta dt", text: "cols"
      assert_select "section.addon-params dl.meta dd", text: "6"
      assert_select "section.addon-params a[href=?]", tools_addon_params_path(state)
    end

    # --- graceful degradation --------------------------------------------------------------------

    test "the addon greys out on a deployment with no sidecar" do
      Tools::OpenscadClient.reset!           # no stub…
      ENV.delete("OPENSCAD_SIDECAR_URL")     # …and no URL: teardown restores both

      get tools_path
      assert_response :success
      assert_select ".addon-card.disabled .addon-title", text: "OpenSCAD"
      assert_select "a.addon-card[href=?]", "/tools/openscad", count: 0

      get tools_openscad_path
      assert_redirected_to tools_path
      assert_equal "OpenSCAD isn't configured on this deployment.", flash[:alert]
    end

    private

    # A real .scad in a user's library, written through the SAME backend-neutral path the addon
    # itself uses — so this seeds correctly on chunk, share and s3 alike.
    #
    # EVERY `name` PASSED HERE MUST BE UNIQUE ACROSS THE FILE, and so must every design `name`
    # posted to #create (which derives its filenames from it). The DB rolls back between tests but
    # the SHARE ROOT does not, and both Share#write and S3#write REFUSE a clobber — so a name reused
    # by a second test is a 500 on the share/s3 legs only.
    def seed_scad(user, name)
      state = user.maker_addon_states.create!(addon_key: "fixture", name: "seed-#{SecureRandom.hex(3)}")
      Maker::Addons::LibraryOutput.write(
        user:, state:, parent_node_id: nil,
        files: [ { name:, bytes: SCAD_FIXTURE.b, content_type: "text/plain", role: "output" } ]
      ).first.node_id
    end

    # A second, confirmed account — for the scoping tests. Random email: a fixed one would collide
    # inside a test that needs two.
    def another_user
      User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                   confirmed_at: Time.current)
    end
  end
end
