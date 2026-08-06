require "test_helper"
require_relative "../../support/fake_addon_source"
require_relative "../../support/fake_service_proxy"
require "tmpdir"

module Tools
  class AddonsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # KEY IS DELIBERATELY NOT "generators", even though title/entry mirror the real Generators
    # addon. `/tools/generators` now DOES resolve to this generic controller (the legacy
    # `resources :generators` route and Tools::GeneratorsController are gone — the real bundle is
    # served by the `addons` Kamal accessory from the chaim354/tinkerex-addons repo in production,
    # and by test/system/addon_bundle_test.rb's own hermetic fixture in CI, not by anything here). A
    # synthetic key keeps THIS suite — which stubs Maker::Addons::Source with fakes — decoupled from
    # either of those, so a change to one cannot silently paper over a break in the other.
    MANIFEST = {
      "key" => "widgetkit", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1",
      "entry" => "generators.js", "pins" => { "makerjs" => "makerjs.js" },
      "services" => [ "fixture-svc" ]
    }.freeze
    FIXTURE_KEY = MANIFEST["key"]

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST ],
        assets: {
          "widgetkit/generators.js" => "export default { mount() {} }",
          # Seeded ONLY so the traversal test can fail for the right reason. If asset_path! ever stops
          # refusing, FakeAddonSource#asset would find this key and the controller would serve it —
          # so the assertion below distinguishes "refused" from the coincidental "not in the hash",
          # which is what made an earlier version of this test pass under mutation.
          "widgetkit/../../secret" => "PWNED"
        }
      )
      @user = User.create!(email: "addons@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      Storage::ChunkStore.reset!
      # Mirrors GeneratorsControllerTest/BoxesControllerTest: on the s3 CI leg, FileLayer.current
      # otherwise resolves to a REAL FileLayer::S3 pointed at CI's stub (non-existent) bucket
      # creds, so an unstubbed save 403s against actual AWS instead of exercising the save path.
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end

    teardown do
      Maker::Addons::Source.reset!
      Maker::Addons::ServiceProxy.reset!
      Rails.cache = @prior_cache
      FileLayer.reset!
      # Centralised rather than per-test `ensure`s: several tests below now set this, and the
      # sibling test that asserts a declared-but-unconfigured service is REFUSED depends on it
      # being absent — so one leak turns that test green for the wrong reason.
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    end

    # Registers a canned response for one full sidecar URL (base + path), via the ServiceProxy seam
    # — never Net::HTTP itself (this repo has no `Object#stub`; see the require at the top of this
    # file for why). Reused across the service tests below.
    def stub_http_ok(full_url, body:, content_type:)
      @fake_service_proxy ||= FakeServiceProxy.new
      Maker::Addons::ServiceProxy.stub = @fake_service_proxy
      @fake_service_proxy.ok(full_url, body: body, content_type: content_type)
    end

    test "requires login" do
      reset!
      get tools_addon_path("widgetkit")
      assert_redirected_to new_user_session_path
    end

    test "renders the shell with the addon's entry URL and host context" do
      get tools_addon_path("widgetkit")
      assert_response :success
      assert_select "[data-controller=addon][data-addon-entry-value=?]",
                    tools_addon_asset_path("widgetkit", "generators.js")
      assert_select "[data-addon-save-url-value=?]", tools_addon_path("widgetkit")
    end

    # A migrated addon's manifest is the only place left to ask for the wide container — the legacy
    # `Tools::BoxesController` view opted in with its own `content_for :container_class` line, and
    # that line lived in the VIEW BODY, which is exactly what a manifest-driven port does not carry
    # over. Asserting the RENDERED `<main>` class, not `@addon.layout`: §14d's recorded lesson is that
    # a test asserting a Ruby value has twice gone green over broken markup, so this has to look at
    # what the layout actually emitted.
    test "an addon declaring layout: wide renders inside the wide container" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST.merge("key" => "widekey", "layout" => "wide") ]
      )

      get tools_addon_path("widekey")

      assert_response :success
      assert_select "main.container.container-wide"
    end

    # MANIFEST (the setup default) has no "layout" key at all — the ordinary case, and it must render
    # the plain narrow container, not merely "not wide" (a typo like `container-wid` would pass a
    # weaker assertion).
    test "an addon with no layout key renders inside the default container only" do
      get tools_addon_path("widgetkit")

      assert_response :success
      assert_select "main.container"
      assert_select "main.container-wide", count: 0
    end

    # The bundle needs these two URLs at mount time — it never guesses at Rails routing, so the shell
    # is the only place they can come from. Asserting the RENDERED attribute, not a Ruby value: this
    # repo has shipped two form bugs where a test asserted a Ruby hash and the real markup was broken
    # (§14d), so a test here has to look at what actually reaches the page.
    test "the shell passes a service base URL and a states URL a bundle can use directly" do
      get tools_addon_path("widgetkit")
      assert_response :success

      # PINS THE WIRE SHAPE: a bundle builds each sidecar call as
      # `${ctx.serviceUrl}${service}/${path}` (e.g. "boxes/generate") by plain string
      # concatenation — it has no route helper of its own — so the base must end in "/" and must
      # not itself already contain "service/<something>". This is the literal contract, not a
      # round-trip through the same helper that built it (§14e: assert the wire format).
      assert_select "[data-addon-service-url-value=?]", "/tools/widgetkit/service/"
      # Also derived from the real route, so a future change to the route's shape fails this test
      # instead of silently drifting from the literal above.
      assert_select "[data-addon-service-url-value=?]",
                    tools_addon_service_path("widgetkit", "S", "P").delete_suffix("S/P")
      assert_select "[data-addon-states-url-value=?]", tools_addon_states_path("widgetkit")
    end

    test "an unknown addon key is a 404, not a 500" do
      get tools_addon_path("nope")
      assert_response :not_found
    end

    test "the addon's pins are merged into the page importmap" do
      get tools_addon_path("widgetkit")
      assert_response :success
      assert_includes response.body, tools_addon_asset_path("widgetkit", "makerjs.js")
    end

    test "serves an addon asset as JavaScript" do
      get tools_addon_asset_path("widgetkit", "generators.js")
      assert_response :success
      assert_equal "text/javascript", response.media_type
      assert_equal "export default { mount() {} }", response.body
    end

    # --- asset caching -----------------------------------------------------------
    #
    # Over HTTP every asset was a fresh TCP connection + GET to the accessory, per module per page
    # view — 12 modules for the boxes bundle, and a 180 KB makerjs.js re-proxied through Ruby on
    # every navigation of the generators one. These use a COUNTING source, because "cached" is a
    # claim about how many times the upstream was ASKED, and no assertion about a response body can
    # observe that.
    class CountingSource < FakeAddonSource
      attr_reader :calls

      def initialize(**kw)
        super
        @calls = Hash.new(0)
      end

      def asset(key, path)
        @calls["#{key}/#{path}"] += 1
        super
      end
    end

    def counting_source
      src = CountingSource.new(manifests: [ MANIFEST ], cacheable: true,
                               assets: { "widgetkit/generators.js" => "export default {}" })
      Maker::Addons::Source.stub = src
      src
    end

    test "a repeated asset request is served from cache, not re-fetched upstream" do
      src = counting_source

      3.times { get tools_addon_asset_path("widgetkit", "generators.js") }

      assert_response :success
      assert_equal 1, src.calls["widgetkit/generators.js"],
                   "the accessory should be asked once, not once per request"
    end

    test "a cacheable asset tells the browser it may keep it" do
      counting_source
      get tools_addon_asset_path("widgetkit", "generators.js")

      assert_response :success
      cache_control = response.headers["Cache-Control"].to_s
      assert_match(/max-age=#{Tools::AddonsController::ASSET_TTL.to_i}/, cache_control)
      assert_match(/private/, cache_control,
                   "this endpoint is behind authenticate_user!; a shared cache must not hold it")
    end

    # THE LOCAL SOURCE IS NEVER CACHED, and this is the arm most likely to be "simplified" away.
    # Source::Local is the dev/test backend reading straight off disk: the fetch costs nothing, and
    # a cached copy would make an addon author's own edit invisible for the whole TTL — delivering
    # the "my fix didn't deploy" confusion to the one person actually editing the file.
    test "the local dev source is re-read every time, never cached" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "widgetkit"))
        asset = File.join(dir, "widgetkit", "generators.js")
        File.write(asset, "export default 1")
        File.write(File.join(dir, "manifests.json"), [ MANIFEST ].to_json)
        Maker::Addons::Source.stub = Maker::Addons::Source::Local.new(dir)

        get tools_addon_asset_path("widgetkit", "generators.js")
        assert_equal "export default 1", response.body

        File.write(asset, "export default 2")
        get tools_addon_asset_path("widgetkit", "generators.js")

        assert_equal "export default 2", response.body, "a dev edit must be visible immediately"
        # NOT `assert_no_match(/max-age/)` — Rails' own default for an uncached response is
        # "max-age=0, private, must-revalidate", so that weaker assertion fails against correct
        # behaviour. What must be absent is the POSITIVE lifetime this endpoint sets when caching.
        assert_no_match(/max-age=#{Tools::AddonsController::ASSET_TTL.to_i}/,
                        response.headers["Cache-Control"].to_s)
      end
    end

    # A FAILURE MUST NOT BE CACHED — the same rule Registry#all's rescue-outside-fetch documents,
    # one layer down. Caching a 404 would turn a two-second accessory blip into five minutes of a
    # broken addon page.
    test "an upstream failure is not cached; the next request tries again" do
      src = counting_source
      src.assets.delete("widgetkit/generators.js")

      get tools_addon_asset_path("widgetkit", "generators.js")
      assert_response :not_found

      src.assets["widgetkit/generators.js"] = "export default {}"
      get tools_addon_asset_path("widgetkit", "generators.js")

      assert_response :success, "the failure must not have been cached"
    end

    test "a missing asset is a 404, not a 500" do
      get tools_addon_asset_path("widgetkit", "nope.js")
      assert_response :not_found
    end

    test "a traversing asset path is refused, not merely absent" do
      # Belt and braces: Source#asset_path! refuses it too, but the controller is the door an
      # attacker actually knocks on, and a 404 here must not depend on the layer below.
      get "/tools/widgetkit/asset/../../secret"
      assert_response :not_found
      assert_no_match(/PWNED/, response.body)
    end

    test "save writes the file to the library and records an AddonState" do
      assert_difference -> { @user.maker_addon_states.count } => 1 do
        post tools_addon_path("widgetkit"), params: {
          name: "3mm birch test",
          data: { generator: "material-test-grid", params: { cols: "5" } }.to_json,
          files: [ { name: "grid.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json
        }
      end
      assert_redirected_to tools_addon_path("widgetkit")

      state = @user.maker_addon_states.last
      assert_equal "widgetkit", state.addon_key
      assert_equal "3mm birch test", state.name
      assert_equal "material-test-grid", state.data["generator"]
      assert_equal 1, state.files.count
    end

    # ---- save: the filename is a filename ------------------------------------------------
    #
    # ASYMMETRIC ACROSS BACKENDS, WHICH IS WHY IT SURVIVED. #parse_files checked `name.present?`
    # and nothing else. Share and S3 each call their own `leaf!` inside #write and refused (as an
    # unrescued FileLayer::NotFound -> 500), but CHUNK has no name check anywhere on the path —
    # Sync::Commit.begin validates the manifest exhaustively and the name not at all, and Node
    # validates `name` for presence only. So the main deployment created a live node called
    # "../../escape.txt" and put it in the changelog, bound for every device's mount.
    #
    # Runs on all three legs and asserts the SAME answer on each, which is the actual fix: the
    # refusal is now at the door, before any backend is asked.
    test "save refuses a traversing filename on every backend" do
      %w[../../escape.txt a/b.svg a\\b.svg . ..].each do |bad|
        assert_no_difference -> { @user.maker_addon_states.count }, "#{bad.inspect} was accepted" do
          assert_no_difference -> { @user.nodes.count } do
            post tools_addon_path("widgetkit"), params: {
              name: "traversal", data: "{}",
              files: [ { name: bad, content_type: "image/svg+xml", body: "<svg/>" } ].to_json
            }
          end
        end
        assert_response :unprocessable_entity, "#{bad.inspect} should be a routine refusal"
      end
    end

    test "save refuses a name that is not a string at all" do
      post tools_addon_path("widgetkit"), params: {
        name: "weird", data: "{}",
        files: [ { name: [ "grid.svg" ], content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }
      assert_response :unprocessable_entity
    end

    # ---- save: one name, one file --------------------------------------------------------
    #
    # The mirror-image defect of the traversal one, and again chunk was the exposed backend: share
    # and s3 refuse a clobber inside #write, while chunk let the SAME save succeed twice and left
    # two sibling nodes with the same name in one directory — POSIX-illegal the moment a device
    # materializes that directory. The answer is now the same 422 everywhere, and no orphan state.
    # ---- save: the eager project-folder nudge --------------------------------------------
    #
    # THE ADDON SAVE WAS THE ONE BROWSER-FACING DOOR WITH NO NUDGE. §14f names seven ways a file
    # reaches `Projects/<slug>/`; the three web upload doors call
    # ProjectFolderIntake#intake_project_folder inline (FilesController#create, #finalize_upload,
    # Projects::UploadsController#create) and a device push got one in 2b9ca85 — but this door, where
    # the user is WATCHING the save complete and the save dialog DEFAULTS to the current project's
    # folder, silently left the file at the project root for up to 15 minutes. On a share/s3
    # deployment there is no `project_folder_intake` schedule at all (ProjectIntakeJob.sweep_all!
    # declines on a scannable backend), so the wait is on Library::ScanJob's own poll.
    #
    # ONE SWEEP FOR THE WHOLE SAVE, not one per file: every file in a save shares `parent_node_id`,
    # and .for_node sweeps the OWNING PROJECT rather than the single node, so the first written file
    # covers all of them. AFTER attach_addon_files_to_current_project, per ProjectFolderIntake's own
    # call-site ordering rule ("that create! MUST run before this call").
    test "save files the output into its category folder without waiting for the sweep" do
      project = @user.maker_projects.create!(name: "Harbor Signs")
      folder = project.ensure_library_folder!(@user)
      name = "harbor-number-#{SecureRandom.hex(4)}.svg"

      post tools_addon_path("widgetkit"), params: {
        name: "harbor v4", data: "{}", parent_node_id: folder.node_id,
        files: [ { name:, content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }
      assert_redirected_to tools_addon_path("widgetkit")

      node = @user.nodes.present.find_by(name:)
      assert node, "the save should have written the file"
      assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id)&.name,
                   "an .svg saved into a project folder should be filed into design/ by the nudge"
    end

    # A SAVE WRITES A SET, AND THE 409 MUST NAME EVERY COLLIDING OUTPUT — a body reporting only a
    # count, or only the first, makes the user guess which drawing the dialog is about. The boxes
    # addon emits `<base>.svg` AND `<base>-plan.svg` in one save, so a plain re-save collides on
    # BOTH; a third, free name is in the mix here to pin the other half (a free output must not be
    # listed).
    #
    # THE TWO-COLLISION SHAPE IS WHAT MAKES THE MUTATION BITE, and an earlier version of this test
    # got that wrong: with only ONE colliding file, narrowing #render_would_replace's `select` to
    # `.first(1)` is a no-op and the mutation stayed GREEN while the comment above it claimed it
    # turned red. The claim was false as written — caught by running the mutation rather than
    # trusting the sentence. Two collisions is the smallest case where "all of them" and "the first
    # of them" actually differ.
    #
    # NOTE WHAT REPLACED WHAT. Two tests here used to assert the OLD outcome — the second copy
    # stranded at the project root, with a flash explaining it (PR #136). The door now catches that
    # case BEFORE writing anything, so the stranding no longer happens and there is no flash to
    # assert. #project_intake_sentence's :conflict branch is NOT dead, though, and is deliberately
    # kept: the door's check and the sweep are not atomic, so a file landing in the category folder
    # between them still ends with the output at the root and the flash saying so. That race is not
    # constructible from out here, which is stated rather than papered over with a test that would
    # only be proving the mock.
    test "the conflict names every colliding output, not just the first" do
      plan = "harbor-plan-#{SecureRandom.hex(4)}.svg"
      body = "harbor-body-#{SecureRandom.hex(4)}.svg"
      clear = "harbor-clear-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(plan, body)

      post tools_addon_path("widgetkit"), params: {
        name: "harbor v4", data: "{}", parent_node_id: folder.node_id,
        files: [ { name: plan, content_type: "image/svg+xml", body: "<svg>a</svg>" },
                 { name: clear, content_type: "image/svg+xml", body: "<svg>b</svg>" },
                 { name: body, content_type: "image/svg+xml", body: "<svg>c</svg>" } ].to_json
      }

      assert_response :conflict
      assert_equal [ { "name" => plan, "folder" => "design" },
                     { "name" => body, "folder" => "design" } ],
                   response.parsed_body["files"],
                   "BOTH collisions are named, in save order, and the free output is not"
      assert_nil @user.nodes.present.find_by(name: clear),
                 "nothing may be written until the user answers — not even the file that would fit"
    end

    # CONFIRMING A MIXED SAVE does both halves: the free name is created at the picked folder (the
    # sweep files it), the taken one replaces in place. Per-file placement is why
    # Maker::Addons::LibraryOutput takes a per-file destination rather than one for the call.
    # THE ALREADY-FILED FILE IS PUT THERE BY A REAL SAVE, not by `nodes.create!`, and that is a
    # correctness requirement of the test rather than tidiness. A hand-built node has no
    # `storage_path`, and on share/s3 that column is how the PORT addresses a file — FileLayer
    # ::Share#write(replace:) resolves the node to reuse by `storage_path`, because `rel` is what it
    # derived the destination from. So a fixture node with a NULL storage_path is a file that cannot
    # exist on those backends, the lookup misses, and a second node is created: chunk green,
    # share/s3 red. Found exactly that way.
    #
    # (The two lookups are DIFFERENT ON PURPOSE and must not be "unified": chunk nodes have no
    # storage_path at all — the changelog is their catalog — so Maker::Addons::LibraryOutput
    # #existing_at asks by (parent, name) there, while the port asks by storage_path here. Each is
    # authoritative for its own backend.)
    test "confirming a mixed save creates the free output and replaces the taken one" do
      clear = "harbor-clear-#{SecureRandom.hex(4)}.svg"
      taken = "harbor-taken-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(taken)
      old = @user.nodes.present.find_by!(name: taken)

      post tools_addon_path("widgetkit"), params: {
        name: "harbor v4", data: "{}", parent_node_id: folder.node_id, overwrite: "1",
        files: [ { name: clear, content_type: "image/svg+xml", body: "<svg>new</svg>" },
                 { name: taken, content_type: "image/svg+xml", body: "<svg>replaced</svg>" } ].to_json
      }
      assert_redirected_to tools_addon_path("widgetkit")

      assert_equal "design", @user.nodes.find_by(node_id: @user.nodes.present.find_by!(name: clear).parent_node_id)&.name,
                   "the free output is created and the nudge files it"
      assert_equal 1, @user.nodes.present.where(name: taken).count
      assert_equal old.node_id, @user.nodes.present.find_by!(name: taken).node_id,
                   "the taken output is replaced in place, keeping its node (§14a)"
      assert_equal "<svg>replaced</svg>", FileLayer.current.read(@user, node_id: old.node_id)
    end

    # ---- save: a re-save asks before it overwrites -----------------------------------------
    #
    # THE BUG THIS CLOSES, reproduced end to end before the fix. Save #1 lands at the project root
    # and the sweep files it into design/. Save #2 under the same name finds the ROOT vacant — copy
    # #1 has moved — so refuse_taken_names! accepts it, and the sweep then cannot place it because
    # design/ is taken. The second copy sits at the project root through every later sweep, forever,
    # with two copies of the file in the library. That is CLAUDE.md §12 item 11 in the wild.
    #
    # 409, NOT 422, and the split is load-bearing rather than cosmetic: 422 (unsupported_operation)
    # means "this name is taken where you asked, pick another", which never succeeds on retry, and
    # 409 means "this WOULD replace something — say yes and I will". A bundle has to tell them apart
    # to know whether to offer an Overwrite button or just an error.
    # A project whose folder already holds `names`, put there by a REAL save so the eager nudge
    # files each one into its category folder — see the mixed-save test for why a hand-built
    # `nodes.create!` is not a substitute (no storage_path, which is how the port addresses a file
    # on share/s3).
    def project_with_filed(*names)
      project = @user.maker_projects.create!(name: "Harbor Signs")
      folder = project.ensure_library_folder!(@user)
      post tools_addon_path("widgetkit"), params: {
        name: "harbor v4", data: "{}", parent_node_id: folder.node_id,
        files: names.map { |n| { name: n, content_type: "image/svg+xml", body: "<svg>v1</svg>" } }.to_json
      }
      assert_redirected_to tools_addon_path("widgetkit")
      [ project, folder ]
    end

    test "re-saving a name already filed in its category folder asks first, writing nothing" do
      name = "harbor-number-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(name)
      filed = @user.nodes.present.find_by!(name:)

      assert_no_difference -> { @user.maker_addon_states.count } do
        assert_no_difference -> { @user.nodes.present.where(name:).count } do
          post tools_addon_path("widgetkit"), params: {
            name: "harbor v4 again", data: "{}", parent_node_id: folder.node_id,
            files: [ { name:, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json
          }
        end
      end
      assert_response :conflict
      assert_equal "would_replace", response.parsed_body["error"]
      assert_equal [ { "name" => name, "folder" => "design" } ], response.parsed_body["files"]
      assert_equal "<svg>v1</svg>", FileLayer.current.read(@user, node_id: filed.node_id),
                   "the existing bytes must be untouched until the user confirms"
    end

    test "confirming the overwrite replaces the filed file in place, keeping its node" do
      name = "harbor-number-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(name)
      filed = @user.nodes.present.find_by!(name:)

      post tools_addon_path("widgetkit"), params: {
        name: "harbor v4 again", data: "{}", parent_node_id: folder.node_id, overwrite: "1",
        files: [ { name:, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json
      }
      assert_redirected_to tools_addon_path("widgetkit")

      assert_equal 1, @user.nodes.present.where(name:).count,
                   "the whole point: ONE copy, not one filed and one stranded at the root"
      assert_equal filed.node_id, @user.nodes.present.find_by!(name:).node_id,
                   "a replace must keep the node — a new node_id orphans every attachment (§14a)"
      assert_equal "<svg>v2</svg>", FileLayer.current.read(@user, node_id: filed.node_id)
      assert_equal "design", @user.nodes.find_by(node_id: @user.nodes.present.find_by!(name:).parent_node_id)&.name
    end

    # A save into an ORDINARY library folder has no category destination, so none of this applies
    # and today's behaviour is untouched. Without this the check would have to guess, and guessing
    # would put a 409 in front of saves that have no sweep coming for them at all.
    test "a save outside a project folder is unaffected by the category check" do
      name = "loose-#{SecureRandom.hex(4)}.svg"
      post tools_addon_path("widgetkit"), params: {
        name: "loose", data: "{}",
        files: [ { name:, content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }
      assert_redirected_to tools_addon_path("widgetkit")
      assert_nil @user.nodes.present.find_by!(name:).parent_node_id
    end

    test "save refuses a name already taken in the destination folder, leaving no orphan state" do
      # A NAME UNIQUE TO THIS RUN, and the reason is a real property of the share leg rather than
      # fussiness: FileLayer::Share#write puts an actual FILE on disk under LIBRARY_PATH, and the
      # test transaction rolls back the `nodes` row but cannot roll back the file. A sibling test
      # in this same file already saves "grid.svg", so reusing that name made THIS test's FIRST
      # save collide with the leftover on disk — a 422 in the wrong place, and only on one of the
      # three legs. The collision this test is about must be the one it creates itself.
      name = "dup-#{SecureRandom.hex(4)}.svg"
      files = [ { name:, content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      post tools_addon_path("widgetkit"), params: { name: "first", data: "{}", files: }
      assert_redirected_to tools_addon_path("widgetkit")
      assert_equal 1, @user.nodes.present.where(name:).count

      assert_no_difference -> { @user.maker_addon_states.count } do
        assert_no_difference -> { @user.nodes.present.where(name:).count } do
          post tools_addon_path("widgetkit"), params: { name: "second", data: "{}", files: }
        end
      end
      assert_response :unprocessable_entity
      assert_equal "unsupported_operation", response.parsed_body["error"]
    end

    # The database cannot see this one: neither file exists yet, so both pass the collision query
    # and chunk writes the duplicate pair itself. Caught in #parse_files instead.
    test "save refuses two files claiming the same name within one save" do
      assert_no_difference -> { @user.maker_addon_states.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "dupes", data: "{}",
          files: [ { name: "grid.svg", content_type: "image/svg+xml", body: "<svg/>" },
                   { name: "grid.svg", content_type: "image/svg+xml", body: "<svg x=''/>" } ].to_json
        }
      end
      assert_response :unprocessable_entity
    end

    # ---- save: the state and its files are one unit of work ------------------------------
    #
    # THE AUDIT'S ACTUAL PROBE, reproduced against a port that fails PART WAY THROUGH rather than
    # up front: four files where the third write raises left two files written, an AddonState row
    # committed for a save that never completed, and a 500. The pre-flight name check now catches
    # the ordinary collision before any write, so this drives the residual case it cannot see — a
    # port refusing at write time (a TOCTOU loser, or any other UnsupportedOperation) — which is
    # exactly what the transaction is for. Uses a fake port so it behaves identically on all three
    # CI legs instead of only on the port-writable ones.
    test "a port refusal part way through a save leaves no AddonState behind" do
      FileLayer.current = FailingPort.new(fail_on_write: 3)

      assert_no_difference -> { @user.maker_addon_states.count } do
        assert_no_difference -> { Maker::AddonFile.count } do
          post tools_addon_path("widgetkit"), params: {
            name: "partial", data: "{}",
            files: (1..4).map { |i| { name: "f#{i}.svg", content_type: "image/svg+xml", body: "<svg/>" } }.to_json
          }
        end
      end
      assert_response :unprocessable_entity, "a clobber is a routine refusal, not a 500"
    ensure
      FileLayer.reset!
    end

    # A port that is writable, counts writes, and refuses the Nth the way a real clobber does.
    # Only the four verbs this path touches are implemented — anything else raising NoMethodError
    # is the honest outcome for a fake that has wandered outside its purpose.
    class FailingPort
      Info = Struct.new(:node_id, :content_token, keyword_init: true)

      def initialize(fail_on_write:)
        @fail_on = fail_on_write
        @writes = 0
      end

      def capabilities
        FileLayer::Capabilities.new(versioned: false, syncable: false, presignable: false,
                                    scannable: true, port_writable: true)
      end

      # `replace:` MIRRORS THE REAL SIGNATURE and is deliberately ignored: this fake exists to fail
      # a write part-way through a multi-file save, and a replace changes nothing about that. What
      # it must NOT do is omit the kwarg — a fake whose arity has drifted from the port's turns
      # every caller into an ArgumentError that says nothing about the behaviour under test.
      def write(_user, parent_node_id:, name:, io:, replace: false)
        @writes += 1
        raise FileLayer::UnsupportedOperation, "#{name.inspect} already exists" if @writes == @fail_on

        Info.new(node_id: SecureRandom.uuid, content_token: "t#{@writes}")
      end

      # Preview enqueue asks; answering nil is enough to make it decline (see LibraryOutput).
      def stat(_user, node_id:) = nil
    end

    test "save refuses a payload over the size cap" do
      post tools_addon_path("widgetkit"), params: {
        name: "huge", data: "{}",
        files: [ { name: "big.svg", content_type: "image/svg+xml",
                   body: "x" * (Tools::AddonsController::MAX_FILE_BYTES + 1) } ].to_json
      }
      assert_response :unprocessable_entity
    end

    test "save refuses a file count over the cap" do
      files = Array.new(Tools::AddonsController::MAX_FILES + 1) do |i|
        { name: "f#{i}.svg", content_type: "image/svg+xml", body: "<svg/>" }
      end
      post tools_addon_path("widgetkit"), params: { name: "many", data: "{}", files: files.to_json }
      assert_response :unprocessable_entity
    end

    test "save refuses malformed files JSON rather than 500ing" do
      post tools_addon_path("widgetkit"), params: { name: "bad", data: "{}", files: "not json" }
      assert_response :unprocessable_entity
    end

    test "service proxies to the sidecar URL the HOST configures" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      # An ALLOWLISTED type, so this test keeps proving what it is named for — that the proxy
      # reaches the host-configured URL and returns its body and type — without also depending on
      # the disposition policy the tests below pin. It used to use image/svg+xml, which now
      # deliberately downgrades (see PROXIED_INLINE_TYPES).
      stub_http_ok("http://sidecar.test/render", body: "SIDECAR-BODY", content_type: "application/json")

      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render"), params: { a: "1" }

      assert_response :success
      assert_equal "SIDECAR-BODY", response.body
      assert_equal "application/json", response.media_type
    end

    # ---- service proxy: what a sidecar may be served AS, under our origin ------------------
    #
    # THE REACHABLE CASE, NOT A HYPOTHETICAL ONE. The service route is `via: %i[get post]` while
    # boxes' /generate is POST-only, so a plain GET reaches Werkzeug's 405 page — Content-Type:
    # text/html — which the old `type: res.content_type, disposition: "inline"` rendered as a
    # document under this app's own origin. No sidecar reflects input today so there is no working
    # XSS, but the channel was open and the first one that does closes it for an attacker.
    test "a sidecar's text/html is never served inline under our origin" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "<script>alert(1)</script>",
                   content_type: "text/html")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      assert_response :success
      assert_equal "application/octet-stream", response.media_type
      assert_match(/attachment/, response.headers["Content-Disposition"].to_s)
    end

    # SVG is script-capable and `nosniff` does not help, so it must not be an inline same-origin
    # document either — and it costs the box generator nothing, because preview.js consumes the
    # render with fetch() + res.text() and re-encodes it into a data: URL itself. Neither header
    # affects a fetch() body, which is what makes this downgrade safe to make.
    test "a sidecar's SVG is delivered as an attachment, not an inline document" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "<svg/>", content_type: "image/svg+xml")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      assert_response :success
      assert_equal "<svg/>", response.body, "the bytes still reach a fetch() caller unchanged"
      assert_equal "application/octet-stream", response.media_type
      assert_match(/attachment/, response.headers["Content-Disposition"].to_s)
    end

    # The other half of the allowlist, and the half that would break the product if it were wrong:
    # gallery.js points an <img src> straight at this proxy for a generator's sample photo, and
    # preview.js branches on a JSON content-type to read a sidecar's error message. Both must stay
    # inline with their own type — a blanket "download everything" fix would have broken both.
    test "allowlisted types keep their own content type and stay inline" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      { "image/jpeg" => "sample", "application/json" => '{"error":"nope"}',
        "text/plain" => "catalog", "model/3mf" => "3MF" }.each do |type, body|
        stub_http_ok("http://sidecar.test/render", body:, content_type: type)

        get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

        assert_response :success
        assert_equal type, response.media_type, "#{type} must survive the proxy unchanged"
        assert_no_match(/attachment/, response.headers["Content-Disposition"].to_s)
      end
    end

    # Flask appends "; charset=utf-8" to text/*, so the parameter has to be stripped before the
    # allowlist is consulted or every text/plain response silently downgrades to a download.
    test "a content type carrying parameters still matches the allowlist" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "hi", content_type: "text/plain; charset=utf-8")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      assert_equal "text/plain", response.media_type
      assert_no_match(/attachment/, response.headers["Content-Disposition"].to_s)
    end

    test "a service the manifest does not declare is refused" do
      # The manifest names WHICH services an addon may reach; the host says WHERE each lives. An
      # addon that could name an arbitrary service — or an arbitrary URL — would be an SSRF
      # primitive pointed at the internal network (spec §4.1).
      ENV["OTHER_SIDECAR_URL"] = "http://other.test"
      # Stubbed so a real answer is a REACHABLE outcome. Without this, a broken guard would still
      # 404 here for an unrelated reason — Net::HTTP failing to resolve "other.test" — which would
      # make the assertion below pass by coincidence rather than by the guard actually firing. The
      # mutation check in step 7 depends on this distinction (§15).
      stub_http_ok("http://other.test/render", body: "SHOULD-NOT-BE-REACHABLE", content_type: "text/plain")

      post tools_addon_service_path(FIXTURE_KEY, "other", "render")
      assert_response :not_found
    ensure
      ENV.delete("OTHER_SIDECAR_URL")
    end

    test "a declared service with no configured URL is refused, not guessed at" do
      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")
      assert_response :not_found
    end

    test "a traversing service path is refused" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      # Stubbed at the WOULD-BE traversal target so a bypassed guard gets a reachable answer instead
      # of a coincidental 404 from Net::HTTP failing on a malformed URL (§15 mutation-check note).
      stub_http_ok("http://sidecar.test/../../admin", body: "SHOULD-NOT-BE-REACHABLE", content_type: "text/plain")

      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "../../admin")
      assert_response :not_found
    ensure
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    end

    test "states lists only this addon's states, for this user only" do
      mine = @user.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "Mine", data: { "g" => "x" })
      @user.maker_addon_states.create!(addon_key: "other-addon", name: "Other addon", data: {})
      stranger = User.create!(email: "stranger@example.com", password: PASSWORD, confirmed_at: Time.current)
      stranger.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "Theirs", data: {})

      get tools_addon_states_path(FIXTURE_KEY)

      assert_response :success
      names = JSON.parse(response.body).map { |s| s["name"] }
      assert_equal [ "Mine" ], names
      assert_equal mine.id, JSON.parse(response.body).first["id"]
    end

    test "states includes each state's files so a bundle can relink its output" do
      state = @user.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "With files", data: {})
      state.files.create!(node_id: "n-1", role: "output", content_type: "image/svg+xml", position: 0)

      get tools_addon_states_path(FIXTURE_KEY)

      files = JSON.parse(response.body).first["files"]
      assert_equal [ { "node_id" => "n-1", "role" => "output" } ], files
    end

    # CONSTANCY IN N, not a literal — same reasoning as test/integration/web/page_query_budget_test.rb
    # (the counts differ per LIBRARY_BACKEND, so a literal would pin one leg and fail the other two).
    # `includes(:files)` is what this guards: drop it and #states goes from a flat query count to one
    # extra SELECT per saved state, invisible to every other test here because none of them save more
    # than one or two states.
    test "states query count does not grow with the number of saved states or their files" do
      seed = lambda do |prefix, count|
        count.times do |i|
          state = @user.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "#{prefix}#{i}", data: {})
          state.files.create!(node_id: "#{prefix}#{i}-file", role: "output")
        end
      end

      seed.call("s", 3)
      get tools_addon_states_path(FIXTURE_KEY)
      assert_response :success
      small = count_queries { get tools_addon_states_path(FIXTURE_KEY) }

      seed.call("l", 12)
      large = count_queries { get tools_addon_states_path(FIXTURE_KEY) }

      assert_equal small, large,
                   "states issued #{small} queries at 3 saved states and #{large} at 15 — " \
                   "it grows with the data. Check the :files eager load."
    end

    # states_key ----------------------------------------------------------------------------------
    # Modeled on the real boxes / boxes-next situation this field exists for: a second addon with
    # its OWN routing key ("widgetkit-next") declares `states_key: "widgetkit"`, so its saves land in
    # — and its listing reads from — the FIRST addon's saved-state rows, not its own. FIXTURE_KEY
    # ("widgetkit") itself declares no states_key anywhere in this suite, so every test elsewhere in
    # this file that uses FIXTURE_KEY is already the "no states_key" regression guard: it asserts
    # `state.addon_key == "widgetkit"` (the routing key) on both the read and the write path.
    STATES_KEY_MANIFEST = MANIFEST.merge("key" => "widgetkit-next", "states_key" => "widgetkit").freeze

    test "an addon declaring states_key reads states stored under that key, not its own routing key" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST, STATES_KEY_MANIFEST ])
      under_declared_key = @user.maker_addon_states.create!(
        addon_key: "widgetkit", name: "Under widgetkit", data: {}
      )
      @user.maker_addon_states.create!(addon_key: "widgetkit-next", name: "Under widgetkit-next", data: {})

      get tools_addon_states_path("widgetkit-next")

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal [ "Under widgetkit" ], body.map { |s| s["name"] }
      assert_equal under_declared_key.id, body.first["id"]
    end

    test "a save from an addon declaring states_key creates a state under the declared key, not its routing key" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST, STATES_KEY_MANIFEST ])

      # A filename NOT reused from any other test in this file: LibraryOutput writes flat to the
      # library root with no clobber-dedup, and on the share backend that write is a REAL filesystem
      # side effect that a test's DB-transaction rollback does not undo — reusing "grid.svg" from
      # "save writes the file to the library..." above collided on that backend (UnsupportedOperation:
      # "grid.svg" already exists), a mistake made once while writing this test and worth the note.
      post tools_addon_path("widgetkit-next"), params: {
        name: "Saved from the trial",
        data: { generator: "material-test-grid" }.to_json,
        files: [ { name: "states-key-trial.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }

      # The redirect stays on the addon's own ROUTING key — states_key is a data scope, not a route.
      assert_redirected_to tools_addon_path("widgetkit-next")
      state = @user.maker_addon_states.find_by!(name: "Saved from the trial")
      assert_equal "widgetkit", state.addon_key
    end

    test "states_key does not widen access to another user's rows" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST, STATES_KEY_MANIFEST ])
      mine = @user.maker_addon_states.create!(addon_key: "widgetkit", name: "Mine", data: {})
      stranger = User.create!(email: "states-key-stranger@example.com", password: PASSWORD, confirmed_at: Time.current)
      stranger.maker_addon_states.create!(addon_key: "widgetkit", name: "Theirs", data: {})

      get tools_addon_states_path("widgetkit-next")

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal [ "Mine" ], body.map { |s| s["name"] }
      assert_equal mine.id, body.first["id"]
    end

    private

    # Mirrors test/integration/web/page_query_budget_test.rb's own helper. SCHEMA/TRANSACTION and
    # PRAGMA are excluded as artifacts of connection setup, not of the request being measured.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
end
