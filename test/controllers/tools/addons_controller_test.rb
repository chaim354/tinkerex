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

    # A SECOND ADDON THAT DECLARES `library:read`, BECAUSE THE GATE IS A PROPERTY OF THE MANIFEST.
    # Keeping MANIFEST above WITHOUT the declaration is what gives the pair its teeth: the same
    # request, against the same node, answers 200 for one key and 403 for the other, so neither
    # test can pass for the wrong reason. Deleting the `permissions` line here reddens the read
    # tests; deleting the controller's check reddens the refusal test.
    READER_MANIFEST = MANIFEST.merge(
      "key" => "readerkit", "title" => "Reader Kit", "entry" => "reader.js",
      "permissions" => [ { "name" => "library:read", "reasoning" => "Opens a .scad you already have" } ]
    ).freeze
    READER_KEY = READER_MANIFEST["key"]

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST, READER_MANIFEST ],
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

    # A REAL multipart file part, not a text field pretending to be one — the whole point of the
    # binary save door is the difference between the two. `binary: true` opens the tempfile in
    # binmode so a 0xFF byte survives the trip into the request.
    #
    # The Tempfiles are held on the test instance: Rack::Test::UploadedFile keeps a reference, but
    # letting Ruby's own GC decide when the backing file is unlinked while a request is mid-parse
    # is a flake waiting to be diagnosed as something else.
    def upload(bytes, filename:, content_type:)
      @uploads ||= []
      file = Tempfile.new([ "addon-part", File.extname(filename) ])
      file.binmode
      file.write(bytes)
      file.rewind
      @uploads << file
      Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: filename)
    end

    # Sets (or, with nil, UNSETS) env for one block and restores exactly what was there. Unsetting
    # matters as much as setting: the defaults test has to prove the fallback, which it cannot do
    # if the ambient environment happens to carry a value.
    def with_env(values)
      prior = values.keys.to_h { |k| [ k, ENV[k] ] }
      values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      prior.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
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

    # ONE ctx BLOB, PARSED — not a `assert_match` on a substring. A data attribute that contains the
    # right characters is not one that parses: the value is HTML-escaped JSON, and the escaping is
    # exactly what a substring assertion cannot see going wrong.
    def rendered_ctx
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      value = css_select("[data-addon-ctx-value]").first["data-addon-ctx-value"]
      JSON.parse(value)
    end

    test "the shell renders a ctx blob carrying the host level and capability map" do
      ctx = rendered_ctx
      assert_equal Maker::Addons::Registry::API_VERSION, ctx["apiVersion"]
      assert_equal Maker::Addons::Host::LEVEL, ctx["hostLevel"]
      assert_equal Maker::Addons::Host.capabilities, ctx["capabilities"]
      assert_equal FIXTURE_KEY, ctx.dig("addon", "key")
    end

    # THE LITERAL IS THE POINT, and it is why this test exists beside the one above rather than
    # inside it: that one derives its expectation from Maker::Addons::Host::LEVEL, so it stays green
    # through any bump and can only see the value failing to REACH the blob. A bundle declaring
    # `min_host: 3` is asking about this number, so the number itself is what has to be asserted.
    # Sibling of host_test.rb's own ledger assertion, one layer down: that one pins the level against
    # the capability set, this one pins that the shell actually serves it.
    test "the host announces level 3" do
      assert_equal 3, rendered_ctx["hostLevel"]
    end

    # ---- the ?state= deep link ------------------------------------------------------------------

    # READS THE RESPONSE THE TEST ITSELF JUST ISSUED, unlike #rendered_ctx which does its own bare
    # GET — every test here needs a query string on the URL, so the request has to be the test's.
    def launch_from_page
      JSON.parse(css_select("[data-addon-ctx-value]").first["data-addon-ctx-value"])["launch"]
    end

    test "a ?state= deep link is resolved into ctx.launch" do
      state = save_box(name: "shelf box")
      get tools_addon_path(FIXTURE_KEY, state: state.id)
      assert_response :success
      assert_equal state.id, launch_from_page["stateId"]
    end

    # ALWAYS PRESENT, NEVER MERELY ABSENT. A missing key reads as `undefined` in JS and cannot be
    # told apart from a host that predates this — the same argument Host::CAPABILITIES makes for
    # every value being a real boolean. `key?` is what asserts that; `assert_nil` alone passes for a
    # blob that has no `launch` at all.
    test "no ?state= means a null stateId, not a missing key" do
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      assert launch_from_page.key?("stateId"), "the key must always be present"
      assert_nil launch_from_page["stateId"]
    end

    # SILENTLY IGNORED, NOT A 404 AND NOT A 500. A stale bookmark, a deleted box or a hand-mangled
    # URL must not take the tool down — the id is a HINT about which item to open, never an
    # authorization decision, so the page renders and the bundle simply starts empty. Contrast the
    # save door, whose caller DOES 404 on an id it cannot resolve: there the id is an instruction
    # about where to WRITE, and guessing wrong writes to the wrong place.
    #
    # THE BLANK IS IN THIS LIST FOR COMPLETENESS, NOT AS A GUARD, and saying so is the point:
    # `find_by(id: "")` was measured to return nil rather than raise, so an empty `?state=` answers
    # a null stateId under `blank?` and under the plausible `nil?` tidy-up alike. That is the
    # opposite of the save door, where `""` must reach the CREATE branch and a `nil?` there is a 404
    # on every such save — which is why THAT half has a mutation-checked guard of its own and this
    # one cannot have.
    test "an unknown, foreign, other-addon or malformed ?state= renders the page with a null stateId" do
      other = User.create!(email: "other3@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "not yours", data: {})
      foreign = @user.maker_addon_states.create!(addon_key: "someone-else", name: "theirs", data: {})

      [ 999_999, theirs.id, foreign.id, "not-a-number", "" ].each do |bad|
        get tools_addon_path(FIXTURE_KEY, state: bad)
        assert_response :success, "?state=#{bad.inspect} must still render the tool"
        assert_nil launch_from_page["stateId"], "?state=#{bad.inspect} must not resolve"
      end
    end

    # A LIST OF IDS RESOLVES TO NOTHING, AND THIS WAS PROBED RATHER THAN REASONED ABOUT. `?state[]=`
    # arrives as an ARRAY and `find_by(id: [...])` is an `IN`: without the type allowlist it
    # RESOLVED, opening whichever of this user's own designs the database returned first — a design
    # nobody named, with nothing anywhere reporting it, and the editor then revising THAT one. Both
    # scopes still held, so nothing is disclosed; it is refused because it is SILENT and because the
    # sibling #resolve_revision_target already refuses the same shape. A guard that exists on one of
    # two identical resolvers and silently does not on the other is this repo's recorded failure
    # shape (§14c).
    test "a ?state= that is not a single id resolves to nothing" do
      first = save_box(name: "first box")
      second = save_box(name: "second box")

      get tools_addon_path(FIXTURE_KEY, state: [ first.id, second.id ])

      assert_response :success
      assert_nil launch_from_page["stateId"]
    end

    test "the ctx blob carries every URL a bundle needs, from the routes rather than literals" do
      ctx = rendered_ctx
      assert_equal tools_addon_path(FIXTURE_KEY),        ctx.dig("urls", "save")
      assert_equal tools_addon_states_path(FIXTURE_KEY), ctx.dig("urls", "states")
      assert_equal library_children_path,                ctx.dig("urls", "children")
      assert_equal library_folders_path,                 ctx.dig("urls", "create")
      # A BASE that a bundle appends "<service>/<path>" to — it must keep its trailing slash, which
      # is the one property of this value a bundle depends on and the easiest to lose.
      assert ctx.dig("urls", "service").end_with?("/")
    end

    # THE TWO REPRESENTATIONS MUST NOT DRIFT. Every value in the ctx blob also reaches the browser
    # as a legacy data attribute, and both must keep answering the same thing for the life of
    # api_version 1 — a bundle built against either one may be running against this host. Asserting
    # each against a separately recomputed expectation cannot see them disagree with each other;
    # reading both out of ONE rendered response is what can.
    #
    # NODEID NEEDS A NORMALISATION, NOT A COINCIDENCE: an HTML data attribute can only ever hold a
    # string, so an absent default folder renders as "" there; the JSON side can and does say
    # `null`. `.to_s` on the ctx side turns that `null` into "" to match — the HTML side has no
    # third option to move toward instead. Both are read by their own consumer as "no folder / use
    # the library root" (the legacy picker treats a blank `parent_node_id` the same as a missing
    # one via `.presence`), so this is the two formats' own ceiling, not a bug being hidden.
    test "the ctx blob and the legacy attributes it duplicates agree, in one render" do
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      mount = css_select("[data-controller=addon]").first
      ctx = JSON.parse(mount["data-addon-ctx-value"])

      assert_equal mount["data-addon-save-url-value"],             ctx.dig("urls", "save")
      assert_equal mount["data-addon-states-url-value"],           ctx.dig("urls", "states")
      assert_equal mount["data-addon-service-url-value"],          ctx.dig("urls", "service")
      assert_equal mount["data-addon-children-url-value"],         ctx.dig("urls", "children")
      assert_equal mount["data-addon-create-url-value"],           ctx.dig("urls", "create")
      assert_equal mount["data-addon-default-folder-value"],       ctx.dig("defaultFolder", "nodeId").to_s
      assert_equal mount["data-addon-default-folder-label-value"], ctx.dig("defaultFolder", "label")
    end

    # THE COMPATIBILITY RULE, WITH TEETH (spec §10.1). The two repos deploy independently: a bundle
    # built against the old ctx may be running against a host built against the new one at any
    # moment. Dropping any of these is invisible to every other test in this suite and breaks
    # production silently, which is precisely why it is asserted as a list rather than trusted.
    test "every pre-SDK data attribute is still emitted" do
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      mount = css_select("[data-controller=addon]").first
      %w[
        data-addon-entry-value data-addon-save-url-value data-addon-service-url-value
        data-addon-states-url-value data-addon-folders-value data-addon-default-folder-value
        data-addon-default-folder-label-value data-addon-children-url-value
        data-addon-create-url-value
      ].each do |attribute|
        assert mount[attribute], "#{attribute} is gone — a published bundle reads it"
      end
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

    # THE SDK IS A HOST PIN, WHICH IS WHAT MAKES IT FREE TO AN ADDON. merged_importmap draws every
    # host pin before the addon's own, so a bundle can `import { host } from "@maker/addon-sdk"`
    # without declaring anything in its manifest. If this pin is ever dropped, every SDK-based
    # bundle fails in the browser with a bare specifier error and nothing server-side notices.
    test "the merged importmap resolves the SDK specifier for every addon" do
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      json = JSON.parse(css_select("script[type='importmap']").first.text)
      assert json["imports"].key?("@maker/addon-sdk"),
             "@maker/addon-sdk is not in the merged importmap: #{json["imports"].keys.sort.inspect}"
      assert_match %r{/maker/addon_sdk}, json["imports"]["@maker/addon-sdk"]
    end

    # THE REASONING STRING IS SHOWN WHERE THERE IS ROOM FOR IT. A gallery card has space for a
    # label; the addon's own page has space for the author's justification, which is the part that
    # tells an operator whether the ask is proportionate.
    test "the addon page lists declared permissions with their reasoning" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST.merge(
          "permissions" => [ { "name" => "library:write", "reasoning" => "to save your box" } ]
        ) ],
        assets: { "#{FIXTURE_KEY}/generators.js" => "export default { mount() {} }" }
      )
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      assert_select ".addon-permissions", text: /Write files to your library/
      assert_select ".addon-permissions", text: /to save your box/
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
      assert_equal [ 1 ], state.revisions.pluck(:revision),
                   "a create is revision 1, so a state's history is complete from its first save"
    end

    # ---- save: revising an existing state --------------------------------------------------
    #
    # `state_id` MEANS "THIS SAVE IS A NEW REVISION OF THAT SAVED ITEM", and its ABSENCE is the
    # compatibility contract: every already-published bundle sends none and must keep creating,
    # byte for byte, because publishing a bundle IS the addon deploy and Rails is never rebuilt
    # (§14c). Every other save test in this file sends no `state_id`, which is what pins that.
    #
    # Saves once and returns the state, so every revision test starts from a REAL save rather than
    # a hand-built row — for two reasons this file already carries scars from: a fixture with no
    # AddonFile rows cannot exercise the file upsert at all, and a `nodes.create!` fixture has a
    # NULL `storage_path`, which is a file that cannot exist on share/s3, where the port addresses
    # a file BY that column (§14a). See the mixed-save test below for the same note at length.
    #
    # THE OUTPUT NAME IS UNIQUE PER CALL BY DEFAULT, which is a property of the share leg rather
    # than fussiness: FileLayer::Share#write puts a real FILE under LIBRARY_PATH, and the test
    # transaction rolls back the `nodes` row but cannot roll back the file — so a fixed name saved
    # by two tests collides on disk in whichever runs second, on one leg only. The sibling test at
    # "save refuses a name already taken…" carries the same warning.
    #
    # `body:` IS A KWARG SO A REPLACE CAN BE PROVEN RATHER THAN ASSUMED. Two saves that both write
    # "<svg/>" leave a byte assertion that passes whether or not the second write happened at all;
    # a test whose subject IS the second write has to be able to name different bytes.
    def save_box(name:, params: { "h" => "60" }, file: "shelf-box-#{SecureRandom.hex(4)}.svg",
                 body: "<svg/>", state_id: nil, parent_node_id: nil, overwrite: nil)
      post tools_addon_path("widgetkit"), params: {
        name:,
        data: { generator: "tray", params: }.to_json,
        files: [ { name: file, content_type: "image/svg+xml", body: } ].to_json,
        # `.compact` so an unset option is ABSENT rather than nil: `state_id: nil` on the wire is
        # the blank the door reads as "no target", but a test asserting the create path must not
        # depend on that reading being right.
        **{ state_id:, parent_node_id:, overwrite: }.compact
      }
      assert_redirected_to tools_addon_path("widgetkit")
      # RETURNS THE STATE THIS SAVE TARGETED, which for a revision is `state_id` and NOT
      # `order(:id).last`. The two agree only while a test has one state; a test that creates a
      # second box and then revises the first would silently get the wrong row back, and every
      # assertion after it would be about a state the save never touched. Still user-scoped, so a
      # helper cannot reach across tenants either.
      #
      # `present?`, NOT PLAIN TRUTHINESS, BECAUSE IT MUST ASK THE DOOR'S OWN QUESTION. `""` is
      # truthy in Ruby and `"".present?` is false, so a `state_id: ""` save — which #create
      # correctly treats as "no target" and lets CREATE — would send this line looking for a state
      # with id `""` and raise RecordNotFound from the HELPER, on a request that succeeded. Two
      # spellings of one question is the drift this file has scars from; keep them identical.
      if state_id.present?
        @user.maker_addon_states.find(state_id)
      else
        @user.maker_addon_states.order(:id).last
      end
    end

    test "a save carrying state_id revises the box instead of creating a second one" do
      state = save_box(name: "shelf box", params: { "h" => "60" })

      assert_no_difference -> { @user.maker_addon_states.count } do
        save_box(name: "shelf box", params: { "h" => "80" }, state_id: state.id)
      end

      state.reload
      assert_equal 2, state.revision
      assert_equal "80", state.data.dig("params", "h"), "the state carries the LATEST params"
      assert_equal [ 1, 2 ], state.revisions.pluck(:revision)
      assert_equal "60", state.revisions.find_by(revision: 1).data.dig("params", "h"),
                   "revision 1 still holds what was saved AT revision 1, not the state's later data"
      assert_equal "80", state.revisions.find_by(revision: 2).data.dig("params", "h")

      # THE STALE ROW STAYS AND ITS POSITION COLLIDES WITH THE NEW ONE. This revision emitted a
      # DIFFERENTLY-NAMED file, so it wrote a new node rather than replacing one, and
      # Maker::Addons::LibraryOutput leaves the previous save's row alone on purpose (that file is
      # still an ordinary library file the user may have renamed or attached, §14c). The visible
      # cost is here: `position` is this save's index into its own outputs, so two rows now hold 0
      # and the number means nothing ACROSS saves. Asserted so the wart is recorded rather than
      # discovered. (Maker::AddonState orders by (position, id) so #states at least serialises them
      # the same way twice — that tiebreak is deliberately NOT asserted here, because SQLite
      # returns rowid order for the tied rows anyway and a test that passes with or without the
      # `:id` cannot show the guard works.)
      assert_equal [ 0, 0 ], state.files.pluck(:position)
    end

    # AN EMPTY `state_id` IS "NO TARGET", NOT A TARGET THAT FAILED TO RESOLVE — AND NOTHING GUARDED
    # THIS UNTIL NOW. `#create` asks `params[:state_id].present?`, and the whole §14c compatibility
    # promise rests on that reading: a bundle rendering an empty hidden `state_id` field is the
    # natural way to say "no target yet", and every such save must CREATE. Swapping the door's
    # `present?` for the plausible tidy-up `unless params[:state_id].nil?` left the entire suite
    # GREEN while turning every one of those saves into a 404 — the door's only explanation of the
    # blank lives in #resolve_revision_target's header, one method away from the line that
    # implements it, which is exactly what makes it easy to "simplify". This test is the guard.
    test "an empty state_id creates, exactly as an absent one does" do
      assert_difference -> { @user.maker_addon_states.count } => 1 do
        save_box(name: "empty hidden field", state_id: "")
      end
    end

    # A REVISION RENAMES THE BOX. `name` is a property of the design, not of one snapshot — a
    # revision row records `data` and nothing else, so a rename has nowhere else to land, and a
    # design the user has renamed must not go on showing its old name in every list.
    test "revising updates the box name" do
      state = save_box(name: "shelf box")
      save_box(name: "shelf box mk2", params: { "h" => "80" }, state_id: state.id)
      assert_equal "shelf box mk2", state.reload.name
    end

    # THE AddonFile ROWS ARE UPSERTED, BECAUSE A REPLACE KEEPS THE NODE (§14a). `maker_addon_files`
    # is unique on [addon_state_id, node_id], so a revision that rewrites the same node in place
    # hands Maker::Addons::LibraryOutput a node its OWN state already has a row for — and creating
    # blindly there is a bare ActiveRecord::RecordNotUnique 500, not a refusal anybody designed.
    #
    # REACHABLE THROUGH THE ORDINARY DOOR, which is why this is the shape the test takes rather
    # than something narrower: the save dialog defaults to the current project's folder, the eager
    # nudge files the first copy into `design/`, and the re-save then resolves to `replace: true`
    # against that same node (see "confirming the overwrite replaces the filed file in place").
    # This is exactly that save, now carrying a `state_id`.
    #
    # AND IT SENDS NO `overwrite`, WHICH IS THIS TEST'S SECOND JOB. It needed one when it was
    # written — the 409 fired on the box's OWN filed output, because nothing yet knew whose file
    # that was — and the collision exemption is precisely what removed the need. The evidence is
    # worth more here than in a purpose-built test: this one predates the exemption and was not
    # written to prove it.
    test "revising a filed output replaces it in place, keeping one node and one file row" do
      name = "harbor-number-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(name)
      filed = @user.nodes.present.find_by!(name:)
      state = @user.maker_addon_states.order(:id).last

      assert_no_difference [ -> { @user.maker_addon_states.count }, -> { Maker::AddonFile.count } ] do
        save_box(name: "harbor v5", file: name, state_id: state.id,
                 parent_node_id: folder.node_id)
      end

      assert_equal 2, state.reload.revision
      assert_equal 1, state.files.count
      assert_equal filed.node_id, state.files.first.node_id,
                   "the replace kept the node, so the state's own file row is the same row (§14a)"
      assert_equal 1, @user.nodes.present.where(name:).count
      assert_equal "<svg/>", FileLayer.current.read(@user, node_id: filed.node_id),
                   "the revision's bytes are what is in the library now"
    end

    # 404 AND NO WRITE — never a 500, and never a silent fallback to CREATING, which would file a
    # revision of someone else's design as a new one of yours: the pile-up this whole feature
    # exists to end, reintroduced by its own error path. Resolved BEFORE any write, so a bad
    # `state_id` costs nothing — hence the `nodes.count` assertion, which is what proves the 404
    # short-circuits #create rather than merely being rendered after the bytes landed.
    test "a state_id belonging to another user is a 404 and writes nothing" do
      other = User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "widgetkit", name: "not yours", data: {})

      assert_no_difference [ -> { @user.maker_addon_states.count }, -> { @user.nodes.count } ] do
        post tools_addon_path("widgetkit"), params: {
          name: "mine now",
          data: { generator: "tray", params: {} }.to_json,
          files: [ { name: "x-#{SecureRandom.hex(4)}.svg", content_type: "image/svg+xml",
                     body: "<svg/>" } ].to_json,
          state_id: theirs.id
        }
      end
      assert_response :not_found
      assert_equal "not_found", response.parsed_body["error"]
      assert_equal 0, theirs.reload.revisions.count
      assert_equal 1, theirs.revision, "a refusal must not bump the counter it refused to advance"
    end

    test "an unknown state_id is a 404 and writes nothing" do
      assert_no_difference [ -> { @user.maker_addon_states.count }, -> { @user.nodes.count } ] do
        post tools_addon_path("widgetkit"), params: {
          name: "ghost",
          data: { generator: "tray", params: {} }.to_json,
          files: [ { name: "x-#{SecureRandom.hex(4)}.svg", content_type: "image/svg+xml",
                     body: "<svg/>" } ].to_json,
          state_id: 999_999
        }
      end
      assert_response :not_found
      assert_equal "not_found", response.parsed_body["error"]
    end

    # A NUMERIC `state_id` RESOLVES. A JSON request body preserves JSON's own types, so a caller
    # posting `{"state_id": 5}` hands the door an Integer — refusing it would answer 404 "no such
    # saved item" about a state that exists and is the caller's own. The allowlist widened; the
    # Array refusal below did not move.
    test "a numeric state_id revises, like the string one" do
      state = save_box(name: "shelf box")
      post tools_addon_path("widgetkit"), params: {
        name: "shelf box", data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: "n-#{SecureRandom.hex(4)}.svg", content_type: "image/svg+xml",
                   body: "<svg/>" } ].to_json,
        state_id: state.id
      }.to_json, headers: { "CONTENT_TYPE" => "application/json" }

      assert_redirected_to tools_addon_path("widgetkit")
      assert_equal 2, state.reload.revision
    end

    # A `state_id` THAT IS NOT ONE ID IS NOT A TARGET. `state_id[]=1&state_id[]=2` arrives as an
    # ARRAY, and `find_by(id: [...])` is an `IN` — it resolves, to whichever of your own boxes the
    # database hands back first, and the revision lands on a design nobody named. Both scopes hold
    # (it is still your own state, under this addon), so nothing is disclosed and nothing crosses a
    # tenant line: what makes it worth refusing is that it is SILENT and it WRITES.
    test "a state_id that is not a single id is a 404" do
      a = save_box(name: "box a")
      b = save_box(name: "box b")

      assert_no_difference [ -> { Maker::AddonStateRevision.count }, -> { @user.nodes.count } ] do
        post tools_addon_path("widgetkit"), params: {
          name: "which one?",
          data: { generator: "tray", params: { "h" => "99" } }.to_json,
          files: [ { name: "x-#{SecureRandom.hex(4)}.svg", content_type: "image/svg+xml",
                     body: "<svg/>" } ].to_json,
          state_id: [ a.id, b.id ]
        }
      end
      assert_response :not_found
      assert_equal [ 1, 1 ], [ a.reload.revision, b.reload.revision ]
    end

    # THE states_key SCOPE, NOT JUST THE USER SCOPE. A state saved under another addon's namespace
    # is not a target, or one addon could append revisions to another's saved work by id alone —
    # and `states_key` is the DATA scope (#states reads the same one), while `key` builds routes.
    test "a state_id from another addon's namespace is a 404" do
      foreign = @user.maker_addon_states.create!(addon_key: "someone-else", name: "theirs", data: {})
      post tools_addon_path("widgetkit"), params: {
        name: "mine",
        data: { generator: "tray", params: {} }.to_json,
        files: [ { name: "x-#{SecureRandom.hex(4)}.svg", content_type: "image/svg+xml",
                   body: "<svg/>" } ].to_json,
        state_id: foreign.id
      }
      assert_response :not_found
      assert_equal 0, foreign.reload.revisions.count
      assert_equal 1, foreign.revision, "a refusal must not bump the counter it refused to advance"
    end

    # ---- save: the collision exemption ---------------------------------------------------
    #
    # THE RULE, IN BOTH DIRECTIONS: a destination collision with a node the TARGET STATE ALREADY
    # OWNS is an approved replace; every other collision keeps today's answer. The three refusal
    # tests below are what stop this from being "naming a state turns the collision checks off".
    #
    # TWO FOLDERS, TWO CHECKS, AND BOTH NEED THE EXEMPTION. A box that was swept into a project's
    # category folder collides THERE, at #resolve_placements (answerable, 409). A box sitting in the
    # plain folder the save dialog picked collides at #refuse_taken_names! (terminal, 422) and never
    # reaches the other check at all — so exempting only one of them leaves the mainline "open a
    # saved design, tweak it, re-save it" flow still refused, which is spec §1.3's dead end.

    test "revising replaces its own file in the picked folder, with no 422 and no overwrite flag" do
      file = "shelf-box-#{SecureRandom.hex(4)}.svg"
      state = save_box(name: "shelf box", file:)
      node_id = state.files.sole.node_id

      state = save_box(name: "shelf box", params: { "h" => "80" }, file:, state_id: state.id,
                       body: "<svg>v2</svg>")

      assert_equal 2, state.reload.revision
      # THE NODE SURVIVES, AND THAT IS THE ASSERTION WITH TEETH. A replace written as
      # delete-then-create passes any bytes-oriented check while orphaning every attachment, BOM
      # link and tag (§14a) — and on chunk a placement that reached LibraryOutput without
      # `replace: true` would not even refuse: it would mint a SECOND node with the same name in
      # the same directory, which is why both halves of the exemption are needed and why the two
      # assertions below are separate.
      assert_equal [ node_id ], state.files.pluck(:node_id)
      assert @user.nodes.present.exists?(node_id:), "the node must still be live"
      assert_equal 1, @user.nodes.present.where(name: file).count, "no second copy"
      assert_equal "<svg>v2</svg>", FileLayer.current.read(@user, node_id:),
                   "and it is the REVISION's bytes at that node, not the original's"
    end

    test "revising still refuses a name owned by a file this box did not produce" do
      taken = "taken-#{SecureRandom.hex(4)}.svg"
      state = save_box(name: "shelf box")
      save_box(name: "unrelated", file: taken)   # a DIFFERENT state owns this name

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: taken, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json,
        state_id: state.id
      }

      assert_response :unprocessable_entity
      assert_equal "unsupported_operation", response.parsed_body["error"]
      assert_equal 1, state.reload.revision, "a refused save must not have counted as a revision"
      assert_equal 1, @user.nodes.present.where(name: taken).count,
                   "and nothing was written — on chunk a missed refusal is a duplicate sibling"
    end

    # THE SAME REFUSAL ON THE OTHER CHECK: a name owned by another state, in a project's category
    # folder, is a 409 question rather than a 422 — and it must STAY a question, not become a
    # silent replace, just because this save happened to name a state.
    test "revising still asks before replacing a filed file another box produced" do
      taken = "harbor-number-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(taken)
      state = save_box(name: "shelf box")   # a different state, owning nothing in that folder

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box", data: "{}", parent_node_id: folder.node_id, state_id: state.id,
        files: [ { name: taken, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json
      }

      assert_response :conflict
      assert_equal "would_replace", response.parsed_body["error"]
      assert_equal 1, state.reload.revision
      assert_equal "<svg>v1</svg>",
                   FileLayer.current.read(@user, node_id: @user.nodes.present.find_by!(name: taken).node_id),
                   "the other box's bytes are untouched until the user answers"
    end

    # THE EXEMPTION IS KEYED BY (parent, name), NOT BY NAME, and nothing pinned that until this
    # test. Owning `clash.svg` SOMEWHERE must not license overwriting a stranger's `clash.svg`
    # in a folder this state owns nothing in — which is what a name-only lookup would do, silently.
    # Every other test here varies the exemption's CONDITIONALITY; this one varies its KEY.
    #
    # ITS MEASURED STATUS, STATED SO IT IS NOT OVER-TRUSTED: against the CURRENT structure this
    # test catches no mutation, and that is a property of the fix rather than a weakness of the
    # test. `except_node_id:` excludes one NODE instead of skipping the query, so even a name-only
    # lookup leaves the stranger's node in the result set and the 422 stands. It bites the moment
    # the exemption is rewritten as a SKIP — the shape this door shipped with for exactly one
    # commit: with that form restored, a name-only lookup turns THIS test red while a
    # parent-scoped one leaves it green. So it is the pin on the KEY, and the sibling below is the
    # pin on the IDENTITY; neither substitutes for the other.
    test "the exemption is scoped to the folder it owns, not to the name" do
      clash = "clash-#{SecureRandom.hex(4)}.svg"
      subfolder = Maker::LibraryFolder.ensure_path!(@user, [ "boxes-#{SecureRandom.hex(4)}" ])
      state = save_box(name: "shelf box", file: clash, parent_node_id: subfolder.node_id)
      save_box(name: "unrelated", file: clash)   # a DIFFERENT state owns that name AT THE ROOT

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: clash, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json,
        state_id: state.id
      }

      assert_response :unprocessable_entity
      assert_equal "unsupported_operation", response.parsed_body["error"]
      assert_equal 1, state.reload.revision
      root_copy = @user.nodes.present.find_by!(parent_node_id: nil, name: clash)
      assert_equal "<svg/>", FileLayer.current.read(@user, node_id: root_copy.node_id),
                   "the stranger's file at the picked folder is untouched"
    end

    # A NAME THIS STATE OWNS CAN STILL BE HELD BY SOMEBODY ELSE'S NODE, AND THE EXEMPTION MUST NOT
    # COVER IT. Two live siblings sharing (parent, name) are reachable on chunk by construction —
    # Sync::Commit validates a manifest exhaustively and the name not at all (§14a), so a device
    # push can land one — and the door's own job is to stop the SAVE side adding more. Before the
    # `except_node_id:` scoping this save answered 302, rewrote the STRANGER's node and adopted it
    # into `state.files`: §14a's orphaning shape with the sign flipped, introduced by the very
    # commit that added the exemption.
    #
    # THE FIXTURE NODES ARE DELIBERATE AND THE §14a WARNING TWO SCREENS UP DOES NOT APPLY. That
    # warning is about a NULL `storage_path` making a replace miss on share/s3 — it bites a test
    # whose save must SUCCEED. This save must be REFUSED, at the door, before a backend is chosen,
    # so the assertion is identical on all three legs and no real bytes are needed to reach it.
    #
    # THE CREATION ORDER IS A CONVENIENCE, NOT WHAT MAKES THIS TEST BITE — worth separating,
    # because it reads like load-bearing setup. `existing_at` is a bare `find_by` with NO `order`,
    # so "the stranger was created first, therefore it is the one returned" is a property of
    # SQLite's rowid scan (what all three legs run here), not of the query. Under the pre-fix skip
    # form the FIRST assertion below goes red either way — that save answered 302 whichever node
    # `existing_at` picked — and only the adoption assertion depends on the stranger being the one
    # it reached.
    test "revising refuses a name it owns when a node it does NOT own also holds it" do
      clash = "clash-#{SecureRandom.hex(4)}.svg"
      stranger = @user.nodes.create!(node_id: SecureRandom.uuid, name: clash, kind: "file")
      state = @user.maker_addon_states.create!(addon_key: "widgetkit", name: "shelf box", data: {})
      mine = @user.nodes.create!(node_id: SecureRandom.uuid, name: clash, kind: "file")
      state.files.create!(node_id: mine.node_id, role: "output", position: 0)

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: clash, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json,
        state_id: state.id
      }

      assert_response :unprocessable_entity
      assert_equal "unsupported_operation", response.parsed_body["error"]
      assert_equal 1, state.reload.revision
      assert_equal [ mine.node_id ], state.files.pluck(:node_id),
                   "the stranger's node must not be ADOPTED into this state's bundle"
      assert_equal 2, @user.nodes.present.where(name: clash).count, "and nothing new was written"
      # THE CONTENT COLUMNS, NOT `updated_at`. The first spelling of this compared `updated_at.to_i`
      # — whole SECONDS, against a write that lands in the same second — so it passed whether or not
      # the stranger was rewritten. These three are nil on a fixture node and a real write sets at
      # least one on every backend (measured: chunk fills current_version_id, share and s3 fill size
      # and content_hash), so the assertion is precision-independent and identical on all three legs.
      assert_equal [ nil, nil, nil ],
                   stranger.reload.slice(:size, :content_hash, :current_version_id).values,
                   "the stranger's node is untouched"
    end

    # WHEN BOTH PLACEMENT ARMS APPLY, ARM 1 WINS — asserted because the comment on
    # #resolve_placements says so and an `if`/`elsif` is one edit away from saying the opposite.
    # Here the picked folder (the project's own root) holds THIS state's copy while the category
    # folder holds a STRANGER's file of the same name. Taking arm 1 asks the question; taking arm 2
    # would treat the save as an approved replace of the state's own copy, answer 302, and leave the
    # sweep unable to file the result. The conservative answer is the right one, and it is the one
    # that goes red if the arms are reordered.
    test "when both placement arms apply the category folder wins and the save asks" do
      name = "prec-#{SecureRandom.hex(4)}.svg"
      _project, folder = project_with_filed(name)
      stranger_filed = @user.nodes.present.find_by!(name:)
      state = @user.maker_addon_states.create!(addon_key: "widgetkit", name: "mine", data: {})
      mine = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                                 parent_node_id: folder.node_id)
      state.files.create!(node_id: mine.node_id, role: "output", position: 0)

      post tools_addon_path("widgetkit"), params: {
        name: "mine", data: "{}", parent_node_id: folder.node_id, state_id: state.id,
        files: [ { name:, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json
      }

      assert_response :conflict
      assert_equal [ { "name" => name, "folder" => "design" } ], response.parsed_body["files"],
                   "the 409 names the CATEGORY folder, which is where the save would land"
      assert_equal "<svg>v1</svg>", FileLayer.current.read(@user, node_id: stranger_filed.node_id)
      assert_equal 1, state.reload.revision
    end

    # THE DEAD END THIS CLOSES (spec §1.3). WITHOUT a state_id, re-saving into the folder the file
    # already sits in is a terminal 422 that no confirmation can answer — that is the bug — and it
    # must STAY refused for a save that does not name the state, or the exemption has quietly
    # become "anyone may clobber anything".
    test "a re-save with no state_id is still refused, which is why revising exists" do
      file = "shelf-box-#{SecureRandom.hex(4)}.svg"
      save_box(name: "shelf box", file:)

      post tools_addon_path("widgetkit"), params: {
        name: "shelf box",
        data: { generator: "tray", params: { "h" => "80" } }.to_json,
        files: [ { name: file, content_type: "image/svg+xml", body: "<svg>v2</svg>" } ].to_json
      }
      assert_response :unprocessable_entity
      assert_equal "unsupported_operation", response.parsed_body["error"]
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

    # ---- save: the library's own reserved names ------------------------------------------
    #
    # THE SAME ASYMMETRY AS THE TRAVERSAL TEST ABOVE, ONE LIST LATER, AND IT SURVIVED FOR THE SAME
    # REASON. Share and S3 each call `observable!` inside #write and refuse a name the library scan
    # will never index (-> FileLayer::NotFound -> this controller's rescue_from -> 422). Chunk never
    # calls the port at all — Maker::Addons::LibraryOutput#write_chunk drives Sync::Commit directly
    # — so there was no guard on the path whatsoever, and the main deployment created a live node
    # bound for the changelog and every device's real mount. Probed through this door before the
    # fix: chunk 302 for every name below, share 422, s3 422 (except `.maker-tmp-x`, 302).
    #
    # RUNS ON ALL THREE LEGS AND ASSERTS THE SAME ANSWER ON EACH — which is the actual fix, exactly
    # as for the traversal case: the refusal is at the door, before any backend is asked.
    #
    # `.maker-tmp-x` IS IN THIS LIST ON PURPOSE and is the one row S3 alone would have allowed
    # (FileLayer::S3#observable! omits TEMP_PREFIX because that adapter writes no temp keys). The
    # door enforces the UNION so a name accepted here is accepted by whichever backend is deployed;
    # see Library::ReservedNames for the full argument. On the s3 leg this row is the one that fails
    # if the door ever narrows to the intersection.
    test "save refuses a reserved library name on every backend" do
      %w[.DS_Store ._resource __MACOSX .Trashes .Spotlight-V100 .trash .maker-tmp-x].each do |bad|
        assert_no_difference -> { @user.maker_addon_states.count }, "#{bad.inspect} was accepted" do
          assert_no_difference -> { @user.nodes.count }, "#{bad.inspect} created a node" do
            post tools_addon_path("widgetkit"), params: {
              name: "reserved", data: "{}",
              files: [ { name: bad, content_type: "text/plain", body: "x" } ].to_json
            }
          end
        end
        assert_response :unprocessable_entity, "#{bad.inspect} should be a routine refusal"
      end
    end

    # THE NEAR MISS, so the guard above is pinned as EXACT-match on `.trash` rather than a prefix.
    # `.trashcan.svg` is an ordinary file the Scanner indexes (`rel == TRASH_PREFIX`), and a save of
    # it must keep working on every backend — a widened guard would refuse a legitimate output and
    # nothing else in this suite would notice.
    test "save accepts a name that merely starts with a reserved prefix" do
      post tools_addon_path("widgetkit"), params: {
        name: "near miss", data: "{}",
        files: [ { name: ".trashcan.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json
      }
      assert_redirected_to tools_addon_path("widgetkit")
      assert @user.nodes.present.exists?(name: ".trashcan.svg"), "the near miss should have saved"
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
                   body: "x" * (Tools::AddonsController.max_bytes + 1) } ].to_json
      }
      assert_response :unprocessable_entity
    end

    test "save refuses a file count over the cap" do
      files = Array.new(Tools::AddonsController.max_files + 1) do |i|
        { name: "f#{i}.svg", content_type: "image/svg+xml", body: "<svg/>" }
      end
      post tools_addon_path("widgetkit"), params: { name: "many", data: "{}", files: files.to_json }
      assert_response :unprocessable_entity
    end

    test "save refuses malformed files JSON rather than 500ing" do
      post tools_addon_path("widgetkit"), params: { name: "bad", data: "{}", files: "not json" }
      assert_response :unprocessable_entity
    end

    # ---- save: real multipart file parts (PR 5, the binary half) --------------------------
    #
    # BYTES THAT ARE NOT VALID UTF-8, ON PURPOSE. A test that saved ASCII through a part would pass
    # against an implementation that decoded, re-encoded or newline-normalized the payload
    # somewhere — exactly the class of defect this door exists to avoid (§14c's CRLF incident). A
    # PNG signature plus a lone 0xFF/0xFE and an embedded CRLF cannot survive any of those quietly.
    BINARY = "\x89PNG\r\n\x1a\n\x00\xFF\xFE\x0Adata".b.freeze

    test "save writes a real multipart file part byte for byte" do
      post tools_addon_path("widgetkit"), params: {
        name: "binary save", data: "{}",
        files: [ { name: "cube.3mf", part: "f0" } ].to_json,
        parts: { f0: upload(BINARY, filename: "cube.3mf", content_type: "model/3mf") }
      }
      assert_redirected_to tools_addon_path("widgetkit")

      node = @user.nodes.present.find_by!(name: "cube.3mf")
      assert_equal BINARY, FileLayer.current.read(@user, node_id: node.node_id).b
    end

    # FROM THE PART, NEVER GUESSED (spec §6.1) — and the JSON entry carries a DIFFERENT, wrong type
    # so the assertion can only pass one way. Reading the name's extension would also answer
    # "model/3mf" here, which is why the part declares something no extension implies.
    test "a part's content type comes from the part, not from the JSON entry or the filename" do
      post tools_addon_path("widgetkit"), params: {
        name: "typed", data: "{}",
        files: [ { name: "typed-part.3mf", content_type: "text/plain", part: "f0" } ].to_json,
        parts: { f0: upload(BINARY, filename: "typed-part.3mf", content_type: "application/vnd.custom") }
      }
      assert_redirected_to tools_addon_path("widgetkit")
      assert_equal "application/vnd.custom", @user.maker_addon_states.last.files.first.content_type
    end

    # ONE ORDERED LIST FOR BOTH SHAPES. `position` is what a bundle relinks its outputs by
    # (AddonFile#position), and a request carrying two collections would have no ordering rule that
    # is not implicit — so the JSON array is the order, whatever each entry's bytes travelled in.
    test "a save mixing an inline body and a part keeps the JSON array's order" do
      post tools_addon_path("widgetkit"), params: {
        name: "mixed", data: "{}",
        files: [ { name: "mixed-plan.svg", content_type: "image/svg+xml", body: "<svg/>" },
                 { name: "mixed-cube.3mf", part: "f0" } ].to_json,
        parts: { f0: upload(BINARY, filename: "mixed-cube.3mf", content_type: "model/3mf") }
      }
      assert_redirected_to tools_addon_path("widgetkit")

      files = @user.maker_addon_states.last.files.order(:position).to_a
      assert_equal %w[image/svg+xml model/3mf], files.map(&:content_type)
      assert_equal [ "mixed-plan.svg", "mixed-cube.3mf" ],
                   files.map { |f| @user.nodes.find_by(node_id: f.node_id).name }
    end

    # THE NAME COMES FROM THE JSON ENTRY, NEVER THE PART'S OWN filename — one source, so the
    # valid_leaf_name?/ReservedNames checks above cover both wire shapes with no second copy. The
    # part here is deliberately named something else; if the part's filename ever won, this saves
    # "whatever-the-browser-said.bin" instead and both assertions flip.
    test "a part entry takes its name from the JSON entry, not the part's filename" do
      post tools_addon_path("widgetkit"), params: {
        name: "named", data: "{}",
        files: [ { name: "chosen.3mf", part: "f0" } ].to_json,
        parts: { f0: upload(BINARY, filename: "whatever-the-browser-said.bin",
                            content_type: "model/3mf") }
      }
      assert_redirected_to tools_addon_path("widgetkit")
      assert @user.nodes.present.exists?(name: "chosen.3mf")
      assert_not @user.nodes.present.exists?(name: "whatever-the-browser-said.bin")
    end

    # …AND THEREFORE THE DOOR'S NAME CHECKS COVER A PART UNCHANGED. Without the single-source rule
    # this would be the one shape with no filename validation — the asymmetry §14c records (chunk
    # has no name check anywhere downstream) arriving through a new door.
    test "a part entry's traversing name is refused like any other" do
      assert_no_difference -> { @user.nodes.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "traversal", data: "{}",
          files: [ { name: "../../escape.3mf", part: "f0" } ].to_json,
          parts: { f0: upload(BINARY, filename: "cube.3mf", content_type: "model/3mf") }
        }
      end
      assert_response :unprocessable_entity
    end

    # A CLIENT-SUPPLIED KEY INDEXING A PARAMS HASH, REFUSED TWO WAYS.
    #
    # `part` is looked up inside `parts[…]`, its own namespace, so it cannot name a top-level param
    # — `part: "name"` would otherwise resolve to the state's own name (a String, which answers
    # #size in CHARACTERS and has no #read: a mis-measured cap and then a 500).
    test "a part naming a top-level param instead of a part is refused" do
      assert_no_difference -> { @user.maker_addon_states.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "sneaky", data: "{}",
          files: [ { name: "out.txt", part: "name" } ].to_json
        }
      end
      assert_response :unprocessable_entity
    end

    # …AND THE NAMESPACE IS LOAD-BEARING ON ITS OWN, WHICH THIS PROVES AND THE TEST ABOVE CANNOT.
    # Above, `part: "name"` resolves to a String and the UploadedFile check would refuse it even
    # without the namespace — so that test exercises the type check, not the scoping. Here the
    # top-level param IS a real upload, so the ONLY thing refusing it is that `parts[…]` is the one
    # place a `part` may name. Without the namespace this writes a file the addon never listed.
    test "a part cannot name a top-level upload that is not one of the declared parts" do
      assert_no_difference -> { @user.maker_addon_states.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "smuggled", data: "{}",
          files: [ { name: "out.txt", part: "cover" } ].to_json,
          cover: upload("smuggled bytes", filename: "cover.png", content_type: "image/png")
        }
      end
      assert_response :unprocessable_entity
    end

    # …and the value inside that namespace must be a real upload, not a text field posing as one.
    test "a parts entry that is a plain text field, not a file, is refused" do
      assert_no_difference -> { @user.maker_addon_states.count } do
        post tools_addon_path("widgetkit"), params: {
          name: "not a file", data: "{}",
          files: [ { name: "out.txt", part: "f0" } ].to_json,
          parts: { f0: "just a string" }
        }
      end
      assert_response :unprocessable_entity
    end

    test "a part entry naming a part that was never posted is refused" do
      post tools_addon_path("widgetkit"), params: {
        name: "missing", data: "{}",
        files: [ { name: "out.txt", part: "f0" } ].to_json
      }
      assert_response :unprocessable_entity
    end

    # ---- save: the caps are explicit and tunable -------------------------------------------
    #
    # THE DEFAULTS ARE TODAY'S NUMBERS (spec §10.3) — asserted so "made explicit" cannot quietly
    # mean "changed".
    test "the save caps default to the numbers every published bundle was built against" do
      with_env("ADDON_SAVE_MAX_FILES" => nil, "ADDON_SAVE_MAX_BYTES" => nil) do
        assert_equal 8, Tools::AddonsController.max_files
        assert_equal 4_000_000, Tools::AddonsController.max_bytes
      end
    end

    test "ADDON_SAVE_MAX_FILES bounds one save's file count" do
      with_env("ADDON_SAVE_MAX_FILES" => "2") do
        files = Array.new(3) { |i| { name: "f#{i}.svg", content_type: "image/svg+xml", body: "<svg/>" } }
        assert_no_difference -> { @user.maker_addon_states.count } do
          post tools_addon_path("widgetkit"), params: { name: "three", data: "{}", files: files.to_json }
        end
        assert_response :unprocessable_entity
      end
    end

    test "ADDON_SAVE_MAX_BYTES bounds one save's TOTAL bytes, not each file's" do
      with_env("ADDON_SAVE_MAX_BYTES" => "10") do
        # Six bytes each: under the cap alone, over it together. A per-FILE cap would accept this,
        # which is the reading the controller's own comment refuses.
        files = [ { name: "a.txt", content_type: "text/plain", body: "aaaaaa" },
                  { name: "b.txt", content_type: "text/plain", body: "bbbbbb" } ]
        assert_no_difference -> { @user.maker_addon_states.count } do
          post tools_addon_path("widgetkit"), params: { name: "pair", data: "{}", files: files.to_json }
        end
        assert_response :unprocessable_entity
      end
    end

    # THE CAP COUNTS A PART'S BYTES TOO — and it must, or accepting parts is a way around it.
    # Sized from the upload's own stat, before anything is read.
    test "a multipart part's bytes count toward the byte cap" do
      with_env("ADDON_SAVE_MAX_BYTES" => "8") do
        assert_no_difference -> { @user.maker_addon_states.count } do
          post tools_addon_path("widgetkit"), params: {
            name: "big part", data: "{}",
            files: [ { name: "cube.3mf", part: "f0" } ].to_json,
            parts: { f0: upload("x" * 9, filename: "cube.3mf", content_type: "model/3mf") }
          }
        end
        assert_response :unprocessable_entity
      end
    end

    # AND A RAISED CAP IS ACTUALLY HONOURED THROUGH A MULTIPART REQUEST. This is the half of the
    # Rack story the controller comment argues: the 4 MiB QueryParser ceiling is a URL-ENCODED
    # limit, so a multipart body sails past it and an operator's raised cap means something. Sized
    # just over the default, so a regression to a hard-coded 4_000_000 fails here.
    test "a raised ADDON_SAVE_MAX_BYTES lets a larger multipart save through" do
      with_env("ADDON_SAVE_MAX_BYTES" => "5000000") do
        post tools_addon_path("widgetkit"), params: {
          name: "over four", data: "{}",
          files: [ { name: "big.3mf", part: "f0" } ].to_json,
          parts: { f0: upload("x" * 4_200_000, filename: "big.3mf", content_type: "model/3mf") }
        }
        assert_redirected_to tools_addon_path("widgetkit")
        node = @user.nodes.present.find_by!(name: "big.3mf")
        assert_equal 4_200_000, FileLayer.current.read(@user, node_id: node.node_id).bytesize
      end
    end

    # A GARBAGE VALUE FALLS BACK TO THE DEFAULT RATHER THAN TO 0. `"four".to_i` is 0, and a 0 cap
    # refuses every save in the deployment — an operator typo must not be able to switch the save
    # door off, nor (with a negative) the cap.
    test "a nonsense cap value falls back to the default instead of refusing everything" do
      with_env("ADDON_SAVE_MAX_FILES" => "four", "ADDON_SAVE_MAX_BYTES" => "-1") do
        assert_equal 8, Tools::AddonsController.max_files
        assert_equal 4_000_000, Tools::AddonsController.max_bytes
      end
    end

    # ---- read: GET /tools/:key/file/:node_id (PR 5) -----------------------------------------
    #
    # THE FIXTURE IS BUILT BY THE REAL SAVE DOOR, NEVER `nodes.create!`. §14a records why: a node
    # made in Ruby has a NULL storage_path, which cannot exist on share or s3 — the read would find
    # nothing there while passing happily on chunk, splitting the legs for a reason that has nothing
    # to do with the endpoint. Going through the door also means these tests exercise the binary
    # save path on the way in, which is how a `.3mf` would really get there.
    def saved_file_node(name:, bytes:, content_type: "application/octet-stream", key: FIXTURE_KEY)
      post tools_addon_path(key), params: {
        name: "save for #{name}", data: "{}",
        files: [ { name: name, part: "f0" } ].to_json,
        parts: { f0: upload(bytes, filename: name, content_type: content_type) }
      }
      assert_redirected_to tools_addon_path(key)
      @user.nodes.present.find_by!(name: name, kind: "file")
    end

    # THREE BACKENDS, THREE Delivery MECHANISMS, AND THE BRANCH IS THE HONEST SHAPE RATHER THAN A
    # CONCESSION. Chunk streams and share sends a file, so Rails holds the bytes and they can be
    # compared; on s3 the port presigns and Rails redirects, so the bytes are never ours — the
    # disposition travels SIGNED INTO THE URL instead (§14a), which is what is read there.
    #
    # EXACTLY THREE ASSERTIONS ON EVERY LEG, WHICH IS NOT COSMETIC: §15 requires the three CI legs
    # to report IDENTICAL counts, so a helper that asserts three things on two backends and one on
    # the third makes the totals differ for a reason nobody reading the summary could locate. Each
    # arm states the same three facts about a different mechanism.
    def assert_delivers(bytes)
      assert_includes [ 200, 302 ], response.status, "unexpected answer: #{response.body}"
      assert_includes delivered_disposition, "attachment"
      # On s3, Rails serves no body at all — the browser is sent to the store — so "no bytes here"
      # is the honest expectation rather than an assertion quietly skipped.
      assert_equal(response.redirect? ? "" : bytes, response.body.b)
    end

    # Where the disposition ACTUALLY IS for whichever mechanism answered: a response header when
    # Rails serves the bytes, and the `response-content-disposition` query parameter the adapter
    # SIGNED INTO the presigned URL when it does not.
    def delivered_disposition
      return response.headers["Content-Disposition"].to_s unless response.redirect?

      signed_param("response-content-disposition")
    end

    test "an addon declaring library:read is served one of the user's own files" do
      node = saved_file_node(name: "part.3mf", bytes: BINARY, content_type: "model/3mf")

      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_delivers BINARY
    end

    # THE GATE. Same user, same node, same request — a different addon key, and the only difference
    # between them is one line in a manifest.
    #
    # AND IT IS DECLARATION CONSISTENCY, NOT CONTAINMENT (spec §8.1). A Ring 1 bundle is same-origin
    # browser code in this very session, so the `widgetkit` page's own JS could simply call
    # `/tools/readerkit/file/<id>` and be served. That is not a hole this test is failing to cover —
    # it is what the gate is FOR: making an addon that reads the library say so on the card the
    # operator reads at publish time. The boundary that is real here is the current_user scope
    # below.
    test "an addon whose manifest does not declare library:read is refused" do
      node = saved_file_node(name: "gated.3mf", bytes: BINARY, content_type: "model/3mf")

      get tools_addon_file_path(FIXTURE_KEY, node.node_id)
      assert_response :forbidden
      assert_equal "forbidden_capability", response.parsed_body["error"]
    end

    # THE SCOPE THAT IS ACTUALLY LOAD-BEARING — AND THE PORT DOUBLE IS WHAT MAKES THIS TEST ABLE TO
    # SEE IT. Written first against the real adapter, and it passed with `current_user.nodes`
    # mutated to `Node.present`: every shipped adapter re-scopes inside its own `live_node!`, so the
    # stranger's node still 404s, just from the port's NotFound instead of this lookup. Green over a
    # guard that had been deleted is this repo's dominant failure shape, so the double answers bytes
    # for ANY id — the way an adapter that trusts its caller legitimately may (the port's contract
    # is that the caller has already decided the request is allowed) — leaving the controller's own
    # scope as the only thing that can refuse.
    #
    # A 404 AND NOT A 403, DELIBERATELY: a stranger's node id and an id that never existed must be
    # indistinguishable, or this endpoint reports which node ids are real.
    test "another user's file is a 404, the same answer an unknown id gets" do
      FileLayer.current = PermissiveDownloadPort.new
      stranger = User.create!(email: "stranger@example.com", password: PASSWORD,
                              confirmed_at: Time.current)
      theirs = stranger.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.3mf", kind: "file")

      get tools_addon_file_path(READER_KEY, theirs.node_id)
      assert_response :not_found
      theirs_body = response.parsed_body

      get tools_addon_file_path(READER_KEY, SecureRandom.uuid)
      assert_response :not_found
      assert_equal theirs_body, response.parsed_body, "a stranger's node must not be distinguishable"
    ensure
      FileLayer.reset!
    end

    # A port that hands over bytes for ANY node id, with no user scope and no liveness check. NOT a
    # strawman: FileLayer's contract is that the CALLER decides whether a request is legitimate
    # (FilesController#blob scopes before calling too), so an adapter is entitled to trust it —
    # chunk/share/s3 all happen to re-check, which is exactly why a test using one of them cannot
    # tell whether this controller's own guards exist.
    class PermissiveDownloadPort
      def download(_user, node_id:, disposition:, content_type: nil)
        FileLayer::Delivery::Stream.new(enum: [ "bytes for #{node_id}" ].each)
      end
    end

    test "a tombstoned file is gone to an addon too" do
      node = saved_file_node(name: "doomed.3mf", bytes: BINARY, content_type: "model/3mf")
      node.update!(deleted: true)

      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_response :not_found
    end

    # A DIRECTORY IS NOT A FILE. Without `kind: "file"` the lookup hands a dir node to #download,
    # whose answer differs per backend — on share that is the poisoned-path family §14b records —
    # and the honest answer for "read me this folder" is that there is no such file.
    #
    # THE SAME PORT DOUBLE, FOR THE SAME REASON AS THE SCOPE TEST ABOVE: against a real adapter this
    # passed with `kind: "file"` deleted, because chunk answers NotFound for a dir node with no
    # current_version and the 404 arrives from the port instead. The double removes that safety net
    # so the controller's own filter is what is being asserted.
    test "a directory node is not readable as a file" do
      # The mkdir goes through the REAL port (LibraryFolder asks it for `capabilities`), so the
      # double is installed after it, not before.
      dir = Maker::LibraryFolder.create_child!(@user, parent_node_id: nil, name: "AddonReadDir")
      FileLayer.current = PermissiveDownloadPort.new

      get tools_addon_file_path(READER_KEY, dir.node_id)
      assert_response :not_found
    ensure
      FileLayer.reset!
    end

    # A `.js` FILE IN THE LIBRARY, WHICH WAS UNREADABLE UNTIL THIS ENDPOINT STOPPED ANSWERING
    # MARCEL'S CONTENT TYPE — found by probing the endpoint, not by reading it.
    # `verify_same_origin_request` is an `append_after_action` that fires on ANY non-XHR JavaScript
    # response, and `fetch` sets no `X-Requested-With`, so every SDK read of a `.js` raised
    # `InvalidCrossOriginRequest` and the addon received a **422 HTML error page** instead of its
    # bytes. Serving every file as `application/octet-stream` removes the condition rather than
    # skipping the guard — see #file's comment for why the skip would have been the worse fix.
    #
    # ASSERTS THE TYPE AS WELL AS THE BYTES: a bytes-only assertion would pass against an
    # implementation that fixed the status and still leaked `text/javascript` into the header.
    test "a .js file in the library reads back as opaque bytes, not as JavaScript" do
      node = saved_file_node(name: "script.js", bytes: "console.log(1)",
                             content_type: "text/javascript")

      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_delivers "console.log(1)"
      assert_not_includes delivered_content_type, "javascript"
    end

    # An SVG through the same door, for the second half of #file's argument: nothing this endpoint
    # serves may be a script-capable document in our origin, whatever the extension says.
    test "an SVG reads back as opaque bytes too" do
      node = saved_file_node(name: "drawing.svg", bytes: "<svg/>", content_type: "image/svg+xml")

      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_delivers "<svg/>"
      assert_not_includes delivered_content_type, "svg"
    end

    # Where the CONTENT TYPE actually is for whichever mechanism answered — a response header when
    # Rails serves the bytes, and the `response-content-type` the adapter signed into the presigned
    # URL when it does not. The sibling of `delivered_disposition`, for the same reason.
    def delivered_content_type
      return response.headers["Content-Type"].to_s unless response.redirect?

      signed_param("response-content-type")
    end

    # ONE query parameter out of the presigned URL, never the whole URL as a haystack. Written the
    # crude way first and the s3 leg caught it: the URL also carries the FILENAME, so
    # `assert_not_includes location, "svg"` fails on `drawing.svg` for a response whose signed
    # content type is `application/octet-stream` — a true assertion failing on the wrong string.
    def signed_param(name)
      CGI.parse(URI.parse(response.location).query.to_s)[name].first.to_s
    end

    test "reading a file requires login" do
      node = saved_file_node(name: "private.3mf", bytes: BINARY, content_type: "model/3mf")
      reset!

      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_redirected_to new_user_session_path
    end

    # AN UNMOUNTED LIBRARY IS RETRYABLE AND MUST NOT READ AS "YOUR FILE IS GONE" (§14a). The
    # class-level rescue_from already answers 503 for the save door; this proves it covers the read
    # door too rather than being shadowed by #file's own NotFound rescue.
    test "an unreachable library answers 503, not 404" do
      FileLayer.current = UnreachablePort.new
      get tools_addon_file_path(READER_KEY, SecureRandom.uuid)
      assert_response :not_found, "no node row means the port is never asked"

      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "away.3mf", kind: "file")
      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_response :service_unavailable
      assert_equal "fetch_error", response.parsed_body["error"]
    ensure
      FileLayer.reset!
    end

    # THE PORT'S OWN NotFound, WHICH MUST NOT REACH THE CLASS-LEVEL 422 ARM. That arm answers
    # "Your library refused that write." — correct for the save door, a lie on a read, and it would
    # send an addon author looking at their own request for a file the user deleted.
    test "the port's NotFound is a 404 here, never the save door's 422" do
      FileLayer.current = MissingBytesPort.new
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "vanished.3mf", kind: "file")

      get tools_addon_file_path(READER_KEY, node.node_id)
      assert_response :not_found
      assert_equal "not_found", response.parsed_body["error"]
    ensure
      FileLayer.reset!
    end

    # THE NO-FALLTHROUGH GUARD, WHICH IS AN ABSENCE AND SO CANNOT BE READ OFF THE CODE. A fourth
    # Delivery mechanism with no consumer here must RAISE (§14a) — a silent `else` would answer a
    # blank 200 with the right filename, and an addon would measure an empty file.
    test "a Delivery variant with no consumer raises rather than serving a blank 200" do
      FileLayer.current = NovelDeliveryPort.new
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "novel.3mf", kind: "file")

      assert_raises(NoMatchingPatternError) do
        get tools_addon_file_path(READER_KEY, node.node_id)
      end
    ensure
      FileLayer.reset!
    end

    # Three one-verb doubles. Each implements ONLY `download`, so a test that wandered onto another
    # port verb fails with a NoMethodError naming it rather than a plausible wrong answer.
    class UnreachablePort
      def download(_user, node_id:, disposition:, content_type: nil)
        raise FileLayer::FetchError, "library not mounted"
      end
    end

    class MissingBytesPort
      def download(_user, node_id:, disposition:, content_type: nil)
        raise FileLayer::NotFound, "no bytes for #{node_id}"
      end
    end

    # A Delivery mechanism this controller has never heard of. `Data.define` rather than a bare
    # Object because the real variants are Data objects, so this fails the pattern match for the
    # reason a genuine fourth variant would, not because it is the wrong kind of thing entirely.
    NovelDelivery = Data.define(:handle)

    class NovelDeliveryPort
      def download(_user, node_id:, disposition:, content_type: nil)
        NovelDelivery.new(handle: node_id)
      end
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

    # THE SDK NOW POSTS JSON (host.service.post), SO THIS IS THE SHAPE THE PROXY ACTUALLY RECEIVES.
    # Two properties in one drive, because they are one request:
    #
    #   1. NESTING SURVIVES. The old FormData transport flattened a nested value to the literal
    #      string "[object Object]", and every real sidecar call sends `{generator, params: {…}}`.
    #   2. NOTHING ELSE IS ADDED. Rails 8 defaults `wrap_parameters format: [:json]` in the
    #      FRAMEWORK — no initializer in this repo, so it does not grep — and ParamsWrapper MERGES a
    #      complete duplicate of the body under a controller-derived key into
    #      `request.request_parameters`, which is exactly what #service forwards. Probed before the
    #      fix: the proxy received an extra `"addon" => {…the whole body again…}`. Inert while the
    #      transport was multipart; live the moment it became JSON. `assert_equal` on the WHOLE hash
    #      rather than `dig`s, because a stray extra key is precisely the defect.
    test "a JSON body reaches the sidecar nested, and with nothing added to it" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/generate", body: "ok", content_type: "text/plain")

      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "generate"),
           params: { generator: "TrayLayout", params: { x: 3, tall: true } }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      assert_response :success
      assert_equal({ "generator" => "TrayLayout", "params" => { "x" => 3, "tall" => true } },
                   @fake_service_proxy.calls.last.params)
    end

    # ---- per-service read timeouts ------------------------------------------------------------
    #
    # The manifest ASKS and the host DECIDES, and the resolved number is only observable here — the
    # controller is where the two meet. Registry proves the parse and ServiceProxy proves the clamp;
    # what these prove is that the controller wires the right addon's right service to the clamp at
    # all, rather than passing nothing and silently keeping 30 s everywhere.
    test "a service with no declared timeout gets the default" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "ok", content_type: "text/plain")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      assert_equal Maker::Addons::ServiceProxy::READ_TIMEOUT,
                   @fake_service_proxy.calls.last.read_timeout
    end

    test "a manifest's service_timeouts entry is applied to that service" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST.merge("service_timeouts" => { "fixture-svc" => 90 }) ], assets: {}
      )
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "ok", content_type: "text/plain")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      assert_equal 90, @fake_service_proxy.calls.last.read_timeout
    end

    # KEYED BY SERVICE NAME, NOT "the addon's timeout". An addon may declare two sidecars and want a
    # long ceiling for only one of them; a per-ADDON reading would hand the fast one the slow one's
    # thread-hold budget. The manifest declares a timeout for a service this request does not name,
    # so the default must survive.
    test "a service_timeouts entry naming a different service does not leak onto this one" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST.merge("service_timeouts" => { "some-other-svc" => 90 }) ], assets: {}
      )
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "ok", content_type: "text/plain")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      assert_equal Maker::Addons::ServiceProxy::READ_TIMEOUT,
                   @fake_service_proxy.calls.last.read_timeout
    end

    test "a manifest asking for more than the host cap gets the cap, and still serves" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST.merge("service_timeouts" => { "fixture-svc" => 9_999 }) ], assets: {}
      )
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "ok", content_type: "text/plain")

      get tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")

      # NOT a 4xx: a remote manifest asking for too much must degrade, not take the addon down.
      assert_response :success
      assert_equal Maker::Addons::ServiceProxy::MAX_TIMEOUT_DEFAULT,
                   @fake_service_proxy.calls.last.read_timeout
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

    test "the states payload carries the current revision number" do
      state = save_box(name: "shelf box")
      get tools_addon_states_path(FIXTURE_KEY)
      assert_response :success
      assert_equal 1, response.parsed_body.first["revision"]

      save_box(name: "shelf box", state_id: state.id)
      get tools_addon_states_path(FIXTURE_KEY)
      assert_equal 2, response.parsed_body.first["revision"]
    end

    # ONE ENTRY PER BOX, FOR THE LIFE OF api_version 1. This is what lets every already-published
    # bundle keep working across this change: a bundle draws a gallery from this list, so a revision
    # showing up as a second saved thing would turn one design into a growing pile — the exact
    # failure the feature exists to end. The history is a SEPARATE endpoint (#revisions) for the same
    # reason and one more: a gallery must not pay for histories nobody opened.
    test "revising does not add a states entry" do
      state = save_box(name: "shelf box")
      save_box(name: "shelf box", state_id: state.id)
      get tools_addon_states_path(FIXTURE_KEY)
      assert_equal 1, response.parsed_body.length
    end

    # ADDITIVE KEYS ONLY, PINNED AS AN EXACT SET. `assert_equal` on the sorted keys is what makes
    # this catch the change a published bundle would actually break on — a REMOVED or RENAMED key —
    # and not merely an added one; a `assert_includes` per key would pass through a rename that
    # dropped the old spelling. Nothing else in this repo can see that break: publishing a bundle IS
    # the addon deploy and Rails is never rebuilt (§14c), so the consumer is in another repo and
    # already running.
    test "the states payload keeps every key a published bundle reads" do
      save_box(name: "shelf box")
      get tools_addon_states_path(FIXTURE_KEY)
      entry = response.parsed_body.first
      assert_equal %w[data files id name revision updated_at], entry.keys.sort
      assert_equal %w[node_id role], entry["files"].first.keys.sort
    end

    # ---- the revision history -----------------------------------------------------------------

    test "revisions are served newest first with their params" do
      state = save_box(name: "shelf box", params: { "h" => "60" })
      save_box(name: "shelf box", params: { "h" => "80" }, state_id: state.id)

      get tools_addon_state_revisions_path(FIXTURE_KEY, state.id)

      assert_response :success
      body = response.parsed_body
      # NEWEST FIRST, and the assertion cannot pass by coincidence: the rows are INSERTED 1 then 2,
      # so an endpoint that forgot to reverse would answer [1, 2] — the opposite array, not an
      # equal-looking one. A reader wants the latest at the top; the association itself is ordered
      # oldest-first because a writer wants maximum(:revision).
      assert_equal [ 2, 1 ], body.map { |r| r["revision"] }
      assert_equal "80", body.first.dig("data", "params", "h")
      assert_equal "60", body.last.dig("data", "params", "h"),
                   "revision 1 must still hold what was saved AT revision 1"
      assert body.first["created_at"].present?, "a snapshot without its timestamp cannot be labelled"
    end

    # THE SAME SCOPE #states READS, ASSERTED AS THREE SEPARATE 404s. A state this addon could not
    # LIST is not a state whose history it may read, and an id that does not resolve must answer
    # identically however it failed — otherwise this endpoint reports which state ids exist and who
    # owns them.
    test "another user's revisions are a 404" do
      other = User.create!(email: "other2@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "not yours", data: {})
      get tools_addon_state_revisions_path(FIXTURE_KEY, theirs.id)
      assert_response :not_found
    end

    test "revisions of a state in another addon's namespace are a 404" do
      foreign = @user.maker_addon_states.create!(addon_key: "someone-else", name: "theirs", data: {})
      get tools_addon_state_revisions_path(FIXTURE_KEY, foreign.id)
      assert_response :not_found
    end

    # AN UNKNOWN ID ANSWERS BYTE-FOR-BYTE WHAT A STRANGER'S DOES, which is the property the two
    # tests above can only half-prove on their own: each of them alone is satisfied by any 404, and
    # a body that differed between the two causes would make this endpoint an existence oracle. The
    # two responses are asserted EQUAL TO EACH OTHER rather than each against its own expected
    # literal — recomputing an expectation twice cannot see the two drift apart, which is the same
    # reasoning the ctx-vs-legacy-attributes test above states at length.
    test "an unknown state id is the same 404, with the same body, as a stranger's" do
      other = User.create!(email: "other4@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: FIXTURE_KEY, name: "not yours", data: {})

      get tools_addon_state_revisions_path(FIXTURE_KEY, 999_999)
      assert_response :not_found
      unknown = response.parsed_body

      get tools_addon_state_revisions_path(FIXTURE_KEY, theirs.id)
      assert_response :not_found
      assert_equal unknown, response.parsed_body
      assert_equal "not_found", unknown["error"]
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

    # Reciprocates STATES_KEY_MANIFEST's claim (Maker::Addons::Registry now refuses an unreciprocated
    # states_key — audit §2.1, Maker::Addons::Registry.states_key_permitted?). A SEPARATE constant
    # rather than changing MANIFEST itself, so the "FIXTURE_KEY declares no states_key anywhere in
    # this suite" guarantee the comment above makes stays true for the other tests in this file.
    RECIPROCATING_MANIFEST = MANIFEST.merge("shares_states_with" => [ "widgetkit-next" ]).freeze

    test "an addon declaring states_key reads states stored under that key, not its own routing key" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ RECIPROCATING_MANIFEST, STATES_KEY_MANIFEST ])
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
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ RECIPROCATING_MANIFEST, STATES_KEY_MANIFEST ])

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
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ RECIPROCATING_MANIFEST, STATES_KEY_MANIFEST ])
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
