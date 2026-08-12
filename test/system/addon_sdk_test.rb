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
