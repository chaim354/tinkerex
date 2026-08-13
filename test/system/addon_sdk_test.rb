require "application_system_test_case"
require_relative "../support/fake_service_proxy"

# THE SDK, IN THE ONLY PLACE IT IS REAL. There is no JS unit-test runner in this repo (no
# package.json, importmap + Propshaft only), and the SDK is transport — a fetch, a CSRF header, a
# 409 round trip, a bare specifier resolving through a per-request merged importmap. None of that is
# observable from a request test; §14e records two CSP defects that shipped past every integration
# test and were caught only by a browser.
#
# HERMETIC, like its sibling addon_bundle_test.rb: this reads test/fixtures/addons, never the
# chaim354/tinkerex-addons working copy, so a fresh clone can run it.
class AddonSdkTest < ApplicationSystemTestCase
  # The sdk-fixture manifest declares `services: ["fixture-svc"]`, so
  # Tools::AddonsController#sidecar_url_for derives exactly this env var name.
  SIDECAR_URL = "http://sdk-sidecar.test".freeze

  # The same art the fixture bundle seeds its <textarea> with. Duplicated deliberately rather than
  # threaded through the page: the assertion is "the bytes the bundle held are the bytes the proxy
  # received", and deriving the expectation from anything the transport touched would let a
  # corruption cancel itself out on both sides.
  ART = "+-+-+-+\n| | | |\n+-+-+-+\n".freeze

  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    sign_in_as "sdk@example.com"
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
    ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    Maker::Addons::ServiceProxy.reset!
  end

  # Installs a recording proxy answering the two endpoints the fixture calls. Returns it so a test
  # can read `.calls` — the same seam tray_layout_test.rb uses, and the only place the browser's
  # own serialization is observable from Ruby.
  def install_sidecar
    ENV["FIXTURE_SVC_SIDECAR_URL"] = SIDECAR_URL
    proxy = FakeServiceProxy.new
    proxy.ok("#{SIDECAR_URL}/echo", body: "echoed", content_type: "text/plain")
    proxy.ok("#{SIDECAR_URL}/slow", body: "slow", content_type: "text/plain")
    Maker::Addons::ServiceProxy.stub = proxy
    proxy
  end

  test "a bundle that imports the SDK mounts, sees the host level, and reads the capability map" do
    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"
    # Asserted from the SERVER's own map rather than a literal, so flipping a capability in PR 4 or
    # PR 5 does not leave a stale literal here passing for the wrong reason.
    caps = Maker::Addons::Host.capabilities
    assert_selector "[data-role=sdk-caps]",
                    text: "write:#{caps["library:write"]} read:#{caps["library:read"]}"
    assert_no_console_errors
  end

  test "files.save writes through the real save door" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Harbor")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-one.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    assert_no_console_errors
  end

  # THE 409 DANCE, ABSORBED. Saving the same name twice is the bug CLAUDE.md §12 item 11 records:
  # the first copy is filed into a category subfolder by the intake sweep, leaving the picked folder
  # vacant, so the door accepts the second save and the sweep then cannot place it. The host answers
  # 409 would_replace BEFORE writing; what this proves is that the SDK reads that, calls onReplace,
  # and re-POSTs with overwrite=1 — the logic every bundle copies by hand today.
  test "files.save asks onReplace on a 409 and replaces when it answers true" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Harbor")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-dup.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-dup.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    # The onReplace callback ran and was told WHICH file and WHICH folder — a bundle that only knew
    # "something conflicted" could not write a truthful prompt. EXACT match, not a substring: this
    # save collides on exactly one file, so the attribute holds exactly one "name@folder" pair — a
    # substring match would pass just as happily on "sdk-dup.svg@undefined", asserting nothing about
    # the folder half of the pair, which is the half that comes from the server's `would_replace`
    # payload and is the actual reason a prompt can name a real destination.
    assert_selector "[data-role=sdk-status][data-replaced='sdk-dup.svg@design']"
    # THE 409 IS THE FLOW, NOT A DEFECT, and Chrome logs a SEVERE console entry for ANY non-2xx
    # fetch response — so an unfiltered assert_no_console_errors fails on the very thing this test
    # exists to exercise (addon_bundle_test.rb hits the identical shape for the identical reason).
    # Narrowly ignored (that exact status, on that exact page) rather than dropping the assertion,
    # so a real error still fails this test.
    assert_no_console_errors ignoring: [ /status of 409 \(Conflict\)/ ]
  end

  # THE TRAVERSAL REFUSAL, IN THE ONE PLACE IT CAN BE OBSERVED. Both arguments of `service.get` land
  # in the same URL — the service NAME and then the PATH — and a `..` in either is normalized out by
  # the BROWSER'S OWN URL PARSER before the request is sent (`/tools/sdk-fixture/service/../../evil/x`
  # leaves as `/tools/evil/x`, verified against WHATWG normalization). So the server's guard is never
  # asked, no server-side test can see the defect, and the refusal has to happen in the SDK. This is
  # the SDK's half of §14a's key_for and §14c's validate_asset_path! rule: REJECT a path, never
  # normalize one.
  #
  # EXACT TEXT, NOT A SUBSTRING — this file's own onReplace assertion records why. A substring match
  # would pass just as happily on "name=AddonError:invalid_argument path=ServiceError:service_error",
  # asserting nothing about the half that regressed.
  test "service refuses a traversing service name and a traversing path before any request" do
    visit "/tools/sdk-fixture"
    click_button "Probe service"
    assert_selector "[data-role=sdk-service]",
                    exact_text: "name=AddonError:invalid_argument path=AddonError:invalid_argument"
    # A SECOND, INDEPENDENT DETECTOR, and deliberately not the primary one: nothing reached the
    # network, so there is no failed fetch for Chrome to log SEVERE. With either guard removed a 404
    # appears here too — but a console check alone would be a weaker guard than the assertion above,
    # which names exactly which of the two halves broke.
    assert_no_console_errors
  end

  # ---- the service plane ---------------------------------------------------------------------

  # THE CRLF DEFECT, PROVED THE ONLY WAY IT CAN BE. A unit assertion on the SDK cannot see this and
  # never could: under the old FormData transport the mangling happened INSIDE THE BROWSER'S
  # multipart serializer, after `body.append(k, v)` returned, so every layer this repo can call
  # directly held a perfectly LF-clean string. The bug was found by tray_layout_test.rb — a real
  # browser round trip — and it has to be pinned by one.
  #
  # ASSERTS ON WHAT THE PROXY RECEIVED, NOT ON THE SDK'S INTENT. `@proxy.calls` is the far side of
  # the whole chain (bundle -> fetch -> Rack -> Rails param parsing -> #service), which is the only
  # vantage point from which "the newlines survived" is a fact rather than a hope.
  test "service.post carries a multi-line value through with its newlines intact" do
    proxy = install_sidecar
    visit "/tools/sdk-fixture"
    click_button "Post art"
    assert_selector "[data-role=sdk-post-result]", text: "echoed"

    layout = proxy.calls.last.params["layout"]
    # THE NARROWEST TRUE THING FIRST, then the two properties it is made of — so a failure names
    # which half broke rather than dumping two blobs of ASCII art at the reader.
    assert_equal ART, layout
    assert_includes layout, "\n", "the line breaks were dropped entirely"
    assert_not_includes layout, "\r", "multipart CRLF normalization is back"
  end

  # THE SECOND DEFECT IN THE SAME LINE, and the reason the fix is JSON rather than a
  # pre-normalization hack: `FormData#append` stringifies a nested value to the literal
  # "[object Object]". Every real sidecar call in the boxes bundle sends `{generator, params: {…}}`,
  # so this is the common shape, not an edge case.
  test "service.post preserves a nested params object instead of flattening it" do
    proxy = install_sidecar
    visit "/tools/sdk-fixture"
    click_button "Post art"
    assert_selector "[data-role=sdk-post-result]", text: "echoed"

    assert_equal({ "generator" => "TrayLayout", "depth" => 3 }, proxy.calls.last.params["nested"])
  end

  # The manifest declares `service_timeouts: {"fixture-svc": 90}`, so this drives the whole chain in
  # one go — a JSON manifest read off disk by Source::Local, parsed by Registry, resolved against
  # the host cap by ServiceProxy.read_timeout_for, and handed to the proxy — rather than the three
  # unit tests each proving their own link and nobody proving they are connected.
  test "a manifest's declared service timeout reaches the proxy for a real browser call" do
    proxy = install_sidecar
    visit "/tools/sdk-fixture"
    click_button "Post art"
    assert_selector "[data-role=sdk-post-result]", text: "echoed"

    assert_equal 90, proxy.calls.last.read_timeout
  end

  # SYNCHRONOUS, AND IT ISSUES NO REQUEST — both asserted at once. The fixture fills this element
  # during mount(), with no await, so a `url` that performed a request could not have produced text
  # by the time the page settles; and the proxy recording stays EMPTY, which is the direct form of
  # "nothing was fetched".
  #
  # The path segment carries a SPACE so the assertion also pins that the builder encodes rather
  # than interpolates — an unencoded space in an <img src> is exactly the kind of thing that works
  # in one browser and not the next.
  test "service.url builds a URL, encodes it, and sends nothing" do
    proxy = install_sidecar
    visit "/tools/sdk-fixture"

    assert_selector "[data-role=sdk-service-url]",
                    exact_text: "/tools/sdk-fixture/service/fixture-svc/sample/a%20b"
    assert_empty proxy.calls, "service.url must not perform a request"
    assert_no_console_errors
  end

  # THE GUARDS ARE SHARED WITH get/post, WHICH IS THE WHOLE SAFETY ARGUMENT FOR THE BUILDER. A URL
  # handed to an `<img src>` is the one case where a traversal is never inspected by a server guard
  # later — there is no request to inspect — so a builder that skipped these would be a traversal
  # hole with a friendly name. EXACT text, not a substring: this file's own onReplace assertion
  # records why a substring match would let half a regression through.
  test "service.url refuses a traversing service name and a traversing path" do
    install_sidecar
    visit "/tools/sdk-fixture"
    click_button "Probe url guards"
    assert_selector "[data-role=sdk-url-guards]",
                    exact_text: "name=AddonError:invalid_argument path=AddonError:invalid_argument"
    assert_no_console_errors
  end

  # AN ABORT IS THE CALLER'S OWN ACTION AND MUST NOT ARRIVE AS A HOST FAILURE. Both halves matter,
  # and the second is the one with teeth: `abort(reason)` makes fetch reject with THAT reason — a
  # plain Error, name "Error" — so an SDK that recognised aborts by `err.name === "AbortError"`
  # would pass `plain=` and report `reasoned=ServiceUnavailableError`, wrapping a cancellation into
  # "retry later, there is nothing to fix now". Reading the class NAME of each is what tells the
  # two implementations apart.
  test "an aborted service call rejects with the caller's own error, not ServiceUnavailableError" do
    install_sidecar
    visit "/tools/sdk-fixture"
    click_button "Probe abort"
    assert_selector "[data-role=sdk-abort]", exact_text: "plain=AbortError reasoned=Error"
    assert_no_console_errors
  end

  # ---- the file plane (PR 5) --------------------------------------------------------------

  # The same bytes the fixture bundle holds, spelled out here rather than derived: an expectation
  # computed from anything the transport touched would let a corruption cancel itself out on both
  # sides, which is the trap ART's own comment records at the top of this file.
  BINARY_HEX = "89504e470d0a1a0a00fffe".freeze
  TEXT_SHOWN = "line one<LF>line two<LF>".freeze

  # BINARY OUT AND BACK, IN THE ONLY PLACE THE TRANSPORT IS REAL. A request test can post a
  # multipart part, and one does (addons_controller_test.rb) — but it builds that part in Ruby, and
  # the thing under test here is the BROWSER's own multipart serializer, which is where §14c's CRLF
  # defect lived and where no Ruby-side assertion can reach.
  #
  # THE TEXT FILE IN THE SAME SAVE IS THE HALF THAT WOULD HAVE CAUGHT THAT DEFECT. `<LF>` is
  # rendered by the fixture precisely because Capybara normalizes whitespace: without spelling the
  # terminators out, "line one\r\nline two" and "line one\nline two" are the same assertion and the
  # corruption this test exists for would pass unseen. If a future change routes a string body
  # through a bare multipart text field, this reads `line one<CR><LF>line two<CR><LF>`.
  test "files.save carries binary and text through a real browser, and files.read brings them back" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Roundtrip")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&bname=rt-part.3mf&tname=rt-notes.txt"
    click_button "Save and read back"

    assert_selector "[data-role=sdk-roundtrip-result]",
                    exact_text: "bin=#{BINARY_HEX} txt=#{TEXT_SHOWN}"
    assert_no_console_errors
  end

  # THE GATE, FROM THE BUNDLE'S SIDE. The sdk-fixture manifest declares `library:read`; the sibling
  # `fixture` addon does not, and asking for the same node through ITS key is refused. Driven here
  # as well as in a request test because this pair is what a bundle author actually meets.
  #
  # DECLARATION CONSISTENCY, NOT CONTAINMENT (spec §8.1), and this test is written so as not to
  # imply otherwise: it asserts that the OTHER ADDON'S endpoint refuses, never that the file is
  # unreachable. A same-origin bundle can call `/tools/sdk-fixture/file/<id>` directly and be served
  # — which is precisely what the second half here does.
  test "the read endpoint refuses an addon whose manifest does not declare library:read" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Gate")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&bname=gate-part.3mf&tname=gate-notes.txt"
    click_button "Save and read back"
    assert_selector "[data-role=sdk-roundtrip-result]", text: "bin=#{BINARY_HEX}"

    node_id = user.maker_addon_states.last.files.first.node_id
    visit "/tools/fixture/file/#{node_id}"
    assert_match(/forbidden_capability/, page.text)
  end

  # pickFile: A SELECTION, AND CANCEL AS A DISTINCT ANSWER. Both halves in one test because the
  # distinction IS the contract — a bundle that cannot tell them apart silently treats Escape as a
  # choice, the defect chooseFolder's own comment records one door over.
  #
  # THE `.svg` IS NOT DECORATION: the fixture asks for `extensions: [".3mf"]`, so a second file the
  # filter must exclude, IN THE SAME COLUMN, is what makes that assertion mean anything. Drop the
  # filter and `pick-other.svg` appears beside `pick-me.3mf` and the assert_no_selector goes red.
  #
  # A PLAIN FOLDER, NOT A PROJECT'S, AND THAT IS THE POINT OF THE PREVIOUS SENTENCE. Written against
  # a project folder first, and §14f's eager intake nudge did exactly its job: it filed the `.3mf`
  # into `models/` and the `.svg` into `design/` before the picker ever opened, so the two files
  # were never in one column and the filter assertion was vacuously true. A folder no project owns
  # is never swept, so both outputs stay put.
  test "files.pickFile returns a selection, filters by extension, and answers null on cancel" do
    user = User.find_by!(email: "sdk@example.com")
    # Created through Maker::LibraryFolder (the one cross-backend mkdir seam) and the FILES through
    # the real save door, for §14a's reason: a node built with nodes.create! has a NULL
    # storage_path, which cannot exist on share or s3.
    folder = Maker::LibraryFolder.create_child!(user, parent_node_id: nil, name: "picker-files")
    visit "/tools/sdk-fixture?parent=#{folder.node_id}&bname=pick-me.3mf&tname=pick-other.svg"
    click_button "Save and read back"
    assert_selector "[data-role=sdk-roundtrip-result]", text: "bin=#{BINARY_HEX}"

    visit "/tools/sdk-fixture"
    click_button "Pick a file"
    assert_selector ".filechooser"
    find(".filechooser-row", text: "picker-files").click
    assert_selector ".filechooser-row", text: "pick-me.3mf"
    assert_no_selector ".filechooser-row", text: "pick-other.svg"
    find(".filechooser-row", text: "pick-me.3mf").click
    click_button "Open"

    assert_selector "[data-role=sdk-picked]", exact_text: "picked file /picker-files/pick-me.3mf"

    # CANCEL, ON A SECOND OPEN. Escape rather than the Cancel button, because Escape is the one a
    # user presses without deciding anything and the one a caller is most likely to conflate with a
    # selection.
    click_button "Pick a file"
    assert_selector ".filechooser"
    find(".filechooser").send_keys(:escape)
    assert_selector "[data-role=sdk-picked]", exact_text: "cancelled"
    assert_no_console_errors
  end

  # ---- state revisions (host level 3) -------------------------------------------------------

  # A REAL SAVE THROUGH THE REAL DOOR, DRIVEN BY THE FIXTURE ITSELF, returning the state it created.
  # Deliberately not `maker_addon_states.create!`: that produces a shape the product never does — a
  # state with no AddonFile rows at all — so every later question about the item's own output
  # (owned_destinations, what a revision may replace) would be asked of a row that has none. This is
  # also the only way to reach the door from a system test, which has no integration POST helper.
  #
  # A PLAIN FOLDER, NEVER A PROJECT'S, for the reason the pickFile test one screen up records: §14f's
  # eager intake nudge files a project folder's outputs into category subfolders the moment they
  # land, which moves the very nodes a revision is about between the save and the assertion.
  def save_through_sdk_fixture(user, folder, fname:)
    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=#{fname}"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    user.maker_addon_states.order(:id).last
  end

  def fill_in_state_id(value)
    find("[data-role=sdk-state-id]").set(value.to_s)
  end

  # THE WIRE FIELD, ASSERTED ON WHAT THE SERVER RECORDED. `state.revision` and the snapshot rows are
  # the far side of the whole chain (bundle -> FormData -> the browser's own serializer -> Rack ->
  # #create), which is the only vantage point from which "the field survived" is a fact rather than
  # a hope — the rule this file already follows for service.post. A test asserting the fixture said
  # "Saved." would pass just as happily on a save that silently created a SECOND item, which is
  # exactly the pile-up this feature exists to end.
  test "files.save carries stateId through to the save door as a revision" do
    user = User.find_by!(email: "sdk@example.com")
    folder = Maker::LibraryFolder.create_child!(user, parent_node_id: nil, name: "sdk-revise")

    state = save_through_sdk_fixture(user, folder, fname: "revise-one.svg")
    assert_equal 1, state.revision

    fill_in_state_id(state.id)
    click_button "Save revision"
    assert_selector "[data-role=sdk-revision-out]", exact_text: "Saved."

    assert_equal 1, user.maker_addon_states.count, "a revision must not create a second saved item"
    assert_equal 2, state.reload.revision
    assert_equal [ 1, 2 ], state.revisions.pluck(:revision)
    assert_equal 2, state.revisions.find_by(revision: 2).data["n"]
    # THE RENAME LANDS ON THE ITEM, NOT THE SNAPSHOT — a second, independent reading of the same
    # fact, since a save that had taken the CREATE branch would have left this name on a new row.
    assert_equal "sdk fixture revised", state.name
    assert_no_console_errors
  end

  # NEWEST FIRST, WITH EACH SNAPSHOT'S OWN PARAMS. EXACT text, not a substring — this file's own
  # onReplace assertion records why: "v2:2" is a substring of "v2:2,v1:-", so a `text:` match would
  # pass on a history that returned only the current revision, which is the likeliest way for this
  # endpoint to be wrong.
  test "state.revisions reads the history newest first, each with the params it was saved with" do
    user = User.find_by!(email: "sdk@example.com")
    folder = Maker::LibraryFolder.create_child!(user, parent_node_id: nil, name: "sdk-history")

    state = save_through_sdk_fixture(user, folder, fname: "history-one.svg")
    fill_in_state_id(state.id)
    click_button "Save revision"
    assert_selector "[data-role=sdk-revision-out]", exact_text: "Saved."

    click_button "Load revisions"
    assert_selector "[data-role=sdk-revisions-out]", exact_text: "v2:2,v1:-"
    assert_no_console_errors
  end

  # REJECTED, NOT ENCODED, AT BOTH DOORS. `encodeURIComponent("..")` is ".." verbatim, so a URL built
  # from one is normalized by THE BROWSER before the request is sent — the route the server guards is
  # never reached and the call misroutes SILENTLY instead of being refused. Only a real browser can
  # observe that, which is why this lives here and not in a request test.
  #
  # THE ARRAY IS A DIFFERENT DEFECT IN THE SAME LINE and is invisible to a request test for the
  # opposite reason — it never survives to become a request at all. `String([n, n])` is "n,n", which
  # the server's own String-or-Integer allowlist (Tools::AddonsController#find_addon_state) cannot
  # refuse because JS already flattened it to a String, and which ActiveRecord's integer cast turns
  # back into n. On the READ door that serves a history nobody asked for; on the WRITE door it
  # appends a revision to a design nobody named.
  #
  # A REAL STATE IS SAVED FIRST, AND THAT IS WHAT MAKES THE ARRAY HALF MEAN ANYTHING. The fixture
  # builds the laundered value out of the id in the input, so removing the guard makes those two
  # calls SUCCEED against a live row rather than 404 — §14c's recorded lesson, where a traversal
  # test aimed at nothing passed under mutation because "refused" and "not found" both produce a 404.
  test "a state id that cannot be spelled is refused before any request, at both doors" do
    user = User.find_by!(email: "sdk@example.com")
    folder = Maker::LibraryFolder.create_child!(user, parent_node_id: nil, name: "sdk-guards")

    state = save_through_sdk_fixture(user, folder, fname: "guards-one.svg")
    fill_in_state_id(state.id)

    click_button "Probe state id guards"
    refused = "AddonError:invalid_argument"
    assert_selector "[data-role=sdk-revisions-guards]",
                    exact_text: "empty=#{refused} dot=#{refused} dotdot=#{refused} " \
                                "array=#{refused} write=#{refused}"
    # A SECOND, INDEPENDENT DETECTOR, and deliberately not the primary one — nothing reached the
    # network, so there is no failed fetch for Chrome to log SEVERE. The same reasoning as the
    # service-traversal test above.
    assert_no_console_errors
  end

  # THE DEEP LINK, AND THE ABSENCE OF ONE. Both halves in one test because the distinction IS the
  # contract: `launch` is always an object and `stateId` is null when there is nothing to open, so a
  # bundle can tell "no deep link" from "a host too old to have one" — which a missing key could not.
  #
  # `old:` IS THE HALF WITH NOTHING ELSE PINNING IT, and it is here because the first version of this
  # test could not fail for it. Every ctx this server serves carries `launch`, so the getter's
  # compatibility default is unreachable from a real page: dropping `stateId: null` while keeping the
  # spread left the whole file GREEN, because the spread still found the server's own key. The
  # fixture calls the getter with a level-2 ctx (no `launch` at all) so the answer a published bundle
  # would get from an older host is a string this assertion can read.
  LEVEL_2_LAUNCH = '{"stateId":null}'.freeze

  test "host.launch carries the resolved deep link, and none is not an error" do
    user = User.find_by!(email: "sdk@example.com")
    folder = Maker::LibraryFolder.create_child!(user, parent_node_id: nil, name: "sdk-launch")

    state = save_through_sdk_fixture(user, folder, fname: "launch-one.svg")

    visit "/tools/sdk-fixture?state=#{state.id}"
    assert_selector "[data-role=sdk-launch]",
                    exact_text: "launch:#{state.id} old:#{LEVEL_2_LAUNCH}"

    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-launch]", exact_text: "launch:none old:#{LEVEL_2_LAUNCH}"
    assert_no_console_errors
  end

  # A MANIFEST WRITTEN AGAINST AN OLDER HOST STILL RUNS. The sdk-fixture declares `min_host: 1`
  # while this host is at whatever Maker::Addons::Host::LEVEL currently says — the compatibility
  # direction that has to keep working, since all three published bundles declare exactly that and
  # Rails is never rebuilt when one is republished. Asserted through a real mount rather than on the
  # Addon struct: `available?` answering true is not the same claim as the page rendering.
  #
  # NEITHER THE NAME NOR THIS COMMENT NAMES THE HOST'S LEVEL, deliberately: every assertion below
  # derives it, so a literal here would be prose that goes stale on the next bump with nothing able
  # to go red — which is exactly what happened to the "level 2" this line used to read.
  test "a min_host 1 manifest still mounts against a newer host" do
    assert_equal 1, Maker::Addons::Registry.find("sdk-fixture").min_host
    assert_operator Maker::Addons::Host::LEVEL, :>, 1, "this test proves nothing at level 1"

    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"
    assert_no_console_errors
  end

  # THE CONNECT -> DISCONNECT -> CONNECT LIFECYCLE, THROUGH A REAL TURBO SOFT NAVIGATION. `visit` is
  # a hard browser load: it tears down the whole JS runtime and re-fetches every module fresh, so
  # addon_sdk.js's module-level `host` binding and `everInitialized` flag start over every time — a
  # `visit`-only test can never exercise addon_controller.js's disconnect() -> teardownHost() call,
  # or the following connect() -> initHost() finding a torn-down host already in place (the
  # `this.disposed` guard added in commit b3f4b78 exists precisely for that in-flight race). Only a
  # Turbo Drive pushState navigation — a `click_link` on a plain, non-turbo-disabled `link_to` — keeps
  # the SAME JS module graph alive across the round trip, the way a real user's session does, so the
  # SDK module instance actually carries state from one mount to the next and this test can catch a
  # regression in that handoff. Neither hop below opts out of Turbo (grep app/views/layouts and this
  # controller's own view: no `data: { turbo: false }` on either link), so both are soft navigations.
  test "a Turbo soft navigation away and back re-mounts the bundle cleanly" do
    # THE ONLY TEST HERE THAT REACHES THE ADDON THROUGH THE GALLERY, so it is the only one that
    # needs the addon to be AVAILABLE. `sdk-fixture`'s manifest declares `services: ["fixture-svc"]`,
    # and an addon whose declared service has no configured URL now greys out with a reason naming
    # it (Maker::Addons::Registry#unavailable_reason) — the check that used to live in the /tools
    # view as `OpenscadClient.configured?` and was lost with that hardcoded card. A greyed card
    # renders as a <div>, not an <a>, so `click_link "SDK Fixture"` finds nothing. Every other test
    # in this file reaches the addon by `visit`, which does not consult `available?` at all.
    #
    # No FakeServiceProxy here on purpose: this test never calls the sidecar, it only needs the
    # deployment to LOOK configured. `install_sidecar` is for the tests that actually call one.
    ENV["FIXTURE_SVC_SIDECAR_URL"] = SIDECAR_URL

    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"

    # AWAY: the top-nav "Tools" link (app/views/layouts/application.html.erb) is a plain link_to —
    # Turbo Drive intercepts it, so this is a pushState visit, not a fresh page load.
    click_link "Tools"
    assert_selector ".tools-grid"
    assert_selector "h1", text: "Tools"

    # BACK: the addon gallery card itself is also a plain link_to (Tools::HomeController#index), so
    # this hop is a soft navigation too — the whole round trip after the initial `visit` above never
    # touches a real browser navigation, which is exactly what makes it able to catch a lifecycle bug
    # a `visit`-based test structurally cannot reach.
    click_link "SDK Fixture"

    # THE SECOND MOUNT. If disconnect() failed to tear the host down, or connect() failed to
    # reinitialize it, this either throws (addon_sdk.js's UNINITIALIZED_HOST proxy names exactly
    # this failure) or silently renders stale state — either way this line does not read "level 1"
    # (rendered fresh by the second mount() call) a second time.
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"
    assert_no_console_errors
  end
end
