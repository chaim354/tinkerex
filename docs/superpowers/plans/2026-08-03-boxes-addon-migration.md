# Boxes addon migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two host surfaces `boxes` needs — a sidecar service proxy and a saved-state listing — then migrate the Box Generator onto the runtime-bundle system, deleting its per-addon Ruby.

**Architecture:** `Tools::AddonsController` gains `service` (proxy to a sidecar named in the addon's manifest, URL resolved from host env — never from the manifest) and `states` (the addon's own `Maker::AddonState` rows as JSON). The Box Generator's UI moves into `tinkerex-addons` as a plain-ESM bundle exporting `mount(element, context)`, and renders its preview SVG directly in an `<img>` rather than asking the host to rasterize.

**Tech Stack:** Rails 8.1, Ruby 3.4.7, importmap-rails, propshaft, Minitest, Capybara + headless Chrome, nginx (the addons container).

---

## Scope

Migration step 3 of `docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md` §7, plus the two SDK surfaces it needs.

**A correction to the spec, recorded here because the spec understated it.** §7 said `openscad` "introduces the service proxy" and implied that was the only new surface. It is not: a survey of both remaining addons found **five** host capabilities missing from the addon API — sidecar proxy, server-side rasterization, saved-state listing, library file read, and library file listing by extension. `boxes` needs the first three; `openscad` needs all five.

**Of those, rasterization turns out not to be needed** — see "The rasterization surface is not built, deliberately" below. So this plan builds **two**.

**NOT in scope:**

- **`openscad`.** Its library-read and file-listing needs are a genuine expansion of the addon API's security surface — an addon bundle being able to request arbitrary library files by `node_id`. That deserves its own decision with `boxes` done and real information in hand, not to be swept in under migration pressure.
- **Moving the GPL sidecars into `tinkerex-addons`.** `openscad_controller.rb` still calls `OpenscadClient` directly, so the openscad sidecar is still invoked from this repo. Both sidecars move when `openscad` migrates. `boxes`' sidecar could move now, but splitting the pair across repos buys nothing and costs a second migration of the same kind.

### The rasterization surface is not built, deliberately

`Tools::BoxesController#preview` renders the sidecar's SVG to PNG via `Maker::Previews::SvgRasterizer.to_png`. But its rescue clause hands back **the raw SVG** when resvg is absent, and `boxpreview_controller.js` assigns whatever comes back to an `<img>` src. **SVG-in-`<img>` therefore already works on this path today** — rasterization is a normalization, not a requirement.

So the bundle renders the SVG as a data URL, exactly as the `generators` bundle already does, and the host needs no rasterize endpoint. This removes a surface that would have had to accept arbitrary bytes and shell out to a binary — the most security-sensitive of the five.

**If a real reason for rasterizing surfaces during implementation** (e.g. a boxes SVG that `<img>` refuses to render), stop and report; do not add a rasterize endpoint without saying why the evidence above was wrong.

**Baseline:** branch off `main` at `00f8a34` or later. `chaim354/tinkerex-addons` is the bundle repo; its accessory is live and serving.

---

## File Structure

**Modified (tinkerex):**

| Path | Change |
|---|---|
| `app/controllers/tools/addons_controller.rb` | `+service`, `+states` |
| `config/routes.rb` | two routes, both **above** the `tools/:key` wildcard |
| `test/controllers/tools/addons_controller_test.rb` | tests for both |
| `test/fixtures/addons/manifests.json` | fixture manifest gains a `services` entry |
| `app/views/tools/home/index.html.erb` | remove the temporary boxes card |
| `config/importmap.rb` | drop the boxes Stimulus pins |

**Deleted (tinkerex):** `app/controllers/tools/boxes_controller.rb`, `app/views/tools/boxes/`, `app/helpers/tools/boxes_helper.rb`, `app/services/boxes_client.rb`, `app/javascript/controllers/{boxfilter,boxpreview,boxsections,traylayout,topview}_controller.js`, `app/javascript/lib/tray_layout.js`, `test/controllers/tools/boxes_controller_test.rb`, `test/services/boxes_client_test.rb`, `test/integration/tools/boxes_live_test.rb`, `test/support/fake_boxes.rb`, `test/system/{box_sections,tray_layout,tray_top_view}_test.rb`, and the `resources :boxes` routes.

**Created (tinkerex-addons):** `addons/boxes/{boxes.js, sections.js, preview.js, tray_layout.js, top_view.js}` and a `boxes` entry in `addons/manifests.json`.

---

## Task 1: The service proxy

**Files:** `app/controllers/tools/addons_controller.rb`, `config/routes.rb`, `test/controllers/tools/addons_controller_test.rb`, `test/fixtures/addons/manifests.json`

- [ ] **Step 1: Give the fixture manifest a service**

In `test/fixtures/addons/manifests.json`, add to the fixture addon:

```json
    "services": ["fixture-svc"]
```

- [ ] **Step 2: Write the failing tests**

Add to `test/controllers/tools/addons_controller_test.rb`. Read the file first — it already has a `setup` that stubs `Maker::Addons::Source` and swaps `Rails.cache`; extend rather than replace it. The fixture addon's key is whatever that file already uses.

```ruby
    test "service proxies to the sidecar URL the HOST configures" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "SIDECAR-BODY", content_type: "image/svg+xml")

      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render"), params: { a: "1" }

      assert_response :success
      assert_equal "SIDECAR-BODY", response.body
      assert_equal "image/svg+xml", response.media_type
    ensure
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    end

    test "a service the manifest does not declare is refused" do
      # The manifest names WHICH services an addon may reach; the host says WHERE each lives. An
      # addon that could name an arbitrary service — or an arbitrary URL — would be an SSRF
      # primitive pointed at the internal network (spec §4.1).
      ENV["OTHER_SIDECAR_URL"] = "http://other.test"
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
      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "../../admin")
      assert_response :not_found
    ensure
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    end
```

**`stub_http_ok` does not exist — you must write it**, and how you write it matters. This repo has **no `minitest/mock`** (minitest 6 dropped it; `test/test_helper.rb:147` records this), so `Object#stub` is unavailable. Follow the existing pattern: `test/support/fake_boxes.rb` and `fake_openscad.rb` are hand-rolled doubles injected through a `.stub=` class attribute. Give the proxy a seam of the same shape rather than stubbing `Net::HTTP` globally, and say what you built.

- [ ] **Step 3: Run — confirm RED**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `NoMethodError: undefined method 'tools_addon_service_path'`.

- [ ] **Step 4: Add the route**

In `config/routes.rb`, **above** the three generic `tools/:key` routes (the ordering comment there explains why — `tools/:key` matches any two-segment path and the guard is mutation-checked):

```ruby
  # An addon reaching its sidecar. The manifest names WHICH service; the host's own env says WHERE —
  # a manifest-supplied URL would be an SSRF primitive aimed at the internal network (spec §4.1).
  match "tools/:key/service/:service/*path", to: "tools/addons#service",
        via: %i[get post], as: :tools_addon_service, format: false
```

- [ ] **Step 5: Implement**

In `app/controllers/tools/addons_controller.rb`:

```ruby
    # Proxy one request to a sidecar the addon's manifest declares. THREE refusals, each 404:
    # a service the manifest does not name, a service the host has no URL for, and a traversing path.
    # The URL never comes from the addon — only from ENV — which is what keeps this from being an
    # SSRF primitive.
    def service
      url = sidecar_url_for(params[:service])
      return head(:not_found) if url.nil?

      path = Maker::Addons::Source.new(url).asset_path!(params[:path])
      res = Maker::Addons::ServiceProxy.current.call(
        method: request.get? ? :get : :post, url:, path:,
        params: request.get? ? request.query_parameters : request.request_parameters
      )
      send_data res.body, type: res.content_type, disposition: "inline", status: res.status
    rescue Maker::Addons::Source::Error, Maker::Addons::ServiceProxy::Error
      head :not_found
    end
```

and in `private`:

```ruby
    # The manifest must DECLARE the service, and the host must have a URL for it. Both, not either.
    def sidecar_url_for(name)
      return nil unless @addon.services.include?(name.to_s)

      ENV["#{name.to_s.upcase.tr('-', '_')}_SIDECAR_URL"].presence
    end
```

**`Addon` has no `services` member yet** — add it to `Data.define` in `app/services/maker/addons/registry.rb`, defaulting to `[]` in `Registry.build` when the manifest omits it, exactly as `pins` does. Update the registry test.

Write `Maker::Addons::ServiceProxy` as a small class with a `.stub=` seam mirroring `Maker::Addons::Source`, returning a value object with `status`, `content_type`, `body`. Bound the response size — pick a cap, state it in a comment, and say what you chose.

- [ ] **Step 6: Run — confirm green**

- [ ] **Step 7: Mutation-check the two refusals (§15) — mandatory**

1. Make `sidecar_url_for` skip the `@addon.services.include?` check. Expect **RED** on "a service the manifest does not declare is refused". Restore, confirm green.
2. Make `service` pass `params[:path]` straight through instead of via `asset_path!`. Expect **RED** on "a traversing service path is refused". Restore, confirm green.

**If either stays green, stop and report.** This plan's predecessors produced four guards that could not go red — two because the test conflated the guarded failure with an unrelated one that produced the same status. Check that the refusal you are asserting is distinguishable from a coincidental 404.

- [ ] **Step 8: `bin/ci`, then commit**

---

## Task 2: The saved-state listing

**Files:** `app/controllers/tools/addons_controller.rb`, `config/routes.rb`, `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
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
```

- [ ] **Step 2: Run — confirm RED** (`undefined method 'tools_addon_states_path'`)

- [ ] **Step 3: Route** — above the wildcard, beside the service route:

```ruby
  get "tools/:key/states", to: "tools/addons#states", as: :tools_addon_states
```

- [ ] **Step 4: Implement**

```ruby
    # The addon's own saved states, for the current user. Scoped BOTH ways — by addon_key and by
    # user — because a bundle is browser code and the scoping is the only thing between one addon
    # and another's saved work.
    def states
      states = current_user.maker_addon_states.for_addon(@addon.key)
                           .includes(:files).order(updated_at: :desc, id: :desc)
      render json: states.map { |s|
        { id: s.id, name: s.name, data: s.data, updated_at: s.updated_at,
          files: s.files.map { |f| { node_id: f.node_id, role: f.role } } }
      }
    end
```

- [ ] **Step 5: Run — confirm green**

- [ ] **Step 6: Mutation-check the scoping (§15) — mandatory**

Drop `.for_addon(@addon.key)`. Expect **RED** (the other-addon state appears). Restore, confirm green.
Then change `current_user.maker_addon_states` to `Maker::AddonState.all`. Expect **RED** (the stranger's state appears). Restore, confirm green.

Both must go red. Cross-user leakage is the one failure here that would matter.

- [ ] **Step 7: `bin/ci`, then commit**

---

## Task 3: The boxes bundle

**Files:** created in `~/Desktop/tinkerex-addons`.

- [ ] **Step 1: Read the shipped implementation carefully before writing anything**

`app/views/tools/boxes/{index,new,show,_form,_field}.html.erb` and `app/javascript/controllers/{boxfilter,boxpreview,boxsections,traylayout,topview}_controller.js`, plus `app/javascript/lib/tray_layout.js`. Keep the existing CSS class names so `app/assets/stylesheets/application.css` still applies.

**Two behaviours are documented as hard-won and must survive** — `test/system/box_sections_test.rb`'s header explains both: `<details>` open/closed state persists in `localStorage` across visits, and the filter must reveal a match hidden inside a collapsed section and then restore the layout. That interaction is two controllers agreeing about who owns `open`.

- [ ] **Step 2: Write the bundle**

`addons/boxes/boxes.js` exporting `{ mount(el, ctx) }`, with the section/preview/tray/top-view logic in sibling modules imported by relative path. Sidecar calls go to `${ctx.serviceUrl}` — **the shell must pass a service URL in its context**; if it does not, add it in Task 4 rather than hardcoding a route in the bundle.

Preview: POST params to the sidecar via the proxy, take the SVG back, and set an `<img>` src to a data URL — as `addons/generators/generators.js` does. **No PNG rasterization.**

- [ ] **Step 3: Manifest entry**

Add a `boxes` entry to `addons/manifests.json` with `services: ["boxes"]`, `entry: "boxes.js"`, and any `pins` the bundle needs.

- [ ] **Step 4: Publish and verify by hand**

`bin/build-push`, then `kamal accessory reboot addons` from the tinkerex repo. Confirm the container serves the new manifest. **Do not proceed to Task 4 until the bundle is actually being served.**

---

## Task 4: Delete the boxes Ruby, deploy, verify

- [ ] **Step 1: Confirm the shell passes what the bundle needs**

The bundle needs a service URL in its mount context. Check `app/views/tools/addons/show.html.erb` and `app/javascript/controllers/addon_controller.js`; add a `serviceUrl` data value if absent, and cover it in the controller test.

- [ ] **Step 2: Delete**

Remove the files and routes listed in "File Structure". Remove the temporary boxes card from `app/views/tools/home/index.html.erb`; boxes now comes through the registered-addon loop. Drop the boxes Stimulus pins from `config/importmap.rb`.

**Keep `BOXES_SIDECAR_URL` in `deploy.yml` and blanked in `deploy.ovh.yml`** — the sidecar is still needed, now reached through the proxy. The widened hygiene guard must stay green.

- [ ] **Step 3: The system tests**

Three system tests cover the boxes UI. They asserted against the old server-rendered markup. Rewrite them against the bundle's markup, preserving **what they prove**, not how: fold state persists across a reload; the filter reveals a match inside a collapsed section and restores the layout afterwards; the editor's preview starts itself with nothing clicked.

These are the repo's most valuable system tests and their header explains why each is browser-only. **If a behaviour genuinely cannot be preserved, stop and report** — do not delete a test to get green.

Note `box_sections_test.rb` has a known flake (`test_what_you_fold_away_stays_folded_on_the_next_visit`). If the rewrite happens to fix it, say so; if it persists, keep it visible rather than quietly dropping the test.

- [ ] **Step 4: `bin/ci`, then deploy**

Use the `/deploy` skill. Unraid only.

- [ ] **Step 5: Verify live, then prove independence again**

Confirm `/tools` lists Boxes and the generator loads against the real sidecar through the proxy. Then change something visible in the boxes bundle, republish, `kamal accessory reboot addons`, and confirm it goes live with the Rails image SHA unchanged. Revert.

- [ ] **Step 6: Docs**

`CLAUDE.md` §14c: the two new surfaces and their refusals. `docs/STATUS.md`: the arc, and that `openscad` remains on its own controller pending a decision on library-read.

---

## Done when

- [ ] Service proxy and states listing exist, with all four refusals mutation-checked
- [ ] The Box Generator runs entirely from the bundle; its Ruby is deleted
- [ ] The three system tests still prove what they proved, against the new markup
- [ ] `bin/ci` green, three legs identical; deployed to all three Unraid backends
- [ ] A boxes bundle change went live with Rails' image SHA unchanged
- [ ] `openscad` still works, untouched
