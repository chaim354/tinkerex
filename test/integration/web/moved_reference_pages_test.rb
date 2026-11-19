require "test_helper"

module Web
  # THE THREE REFERENCE PAGES MOVED TO THE SECTIONS THEY SERVE (2026-09-10). They lived at
  # `/settings/*` while `ShellHelper::SECTIONS` lit Models and Inventory for them, so clicking
  # Settings landed a maker on a page where Settings went dark and another rail item was
  # highlighted. The map was not the thing that was wrong; the URLs were.
  #
  # SHELVES MOVED BACK IN SLICE 5 (structural redesign). Models stopped being a section and became a
  # Library view, so the section a shelf serves is Settings, and `/settings/shelves` is the page
  # again, lighting Settings. Since 2026-10-20 that page is the project-folder Shelves (it was
  # Filing, whose `/settings/filing` now redirects there too); the model catalog's shelves became a
  # built-in rule with no page. Suppliers and locations stay under Inventory, which is still a
  # section. The URL and the lit item still agree on all three.
  #
  # THREE THINGS HERE FAIL SILENTLY AND THAT IS WHY THIS FILE EXISTS:
  #
  #   1. THE SHADOWING. `/models/shelves` and `/inventory/suppliers` are static segments under a
  #      resourceful path, so if the parent is declared FIRST they match as `models#show id=shelves`
  #      and `inventory_items#show id=suppliers` — a 404 on a page (or a redirect) that exists. That
  #      is exactly what happened when these were moved and left below their parents, and nothing
  #      about the route file looks wrong when it does.
  #   2. THE REDIRECTS. A 301 that quietly stops being declared costs a maker their bookmarks, and
  #      no other test in the suite visits the old paths — they would simply 404 with nobody asking.
  #   3. THE LOOP. Shelves have now lived at both `/settings/shelves` and `/models/shelves`, and each
  #      move left a redirect behind. Keep both and declare the old one first, and `/settings/shelves`
  #      301s to `/models/shelves`, which 301s straight back — every redirect is individually
  #      "permanent" and correct-looking, and the page never renders. Hence the old paths are
  #      FOLLOWED here, not just read: a redirect has to land somewhere that renders.
  class MovedReferencePagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "moved@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "each page lives under the section it serves and renders there" do
      { "/settings/shelves" => settings_shelves_path,
        "/inventory/suppliers" => suppliers_path,
        "/inventory/locations" => locations_path }.each do |want, got|
        assert_equal want, got, "the helper no longer points at the section it serves"
        get got
        # NOT MERELY ROUTABLE — RENDERED. A shadowed path routes perfectly well to the wrong
        # controller, and a looped one answers 301; only a 2xx says the page itself answered.
        assert_response :success, "#{want} did not render — is it shadowed, or redirecting away?"
      end
    end

    test "the old paths still redirect, permanently, to a page that renders" do
      { "/models/shelves" => "/settings/shelves",
        "/settings/filing" => "/settings/shelves",
        "/settings/suppliers" => "/inventory/suppliers",
        "/settings/locations" => "/inventory/locations" }.each do |old, want|
        get old
        assert_response :moved_permanently, "#{old} stopped redirecting — that is a maker's bookmark"
        assert_equal want, response.headers["Location"].sub(%r{\Ahttps?://[^/]+}, "")
        follow_redirect!
        assert_response :success, "#{old} redirects to #{want}, which does not render — a loop?"
      end
    end

    test "the strip lights the place each page serves, and the URL now agrees with it" do
      # THE POINT OF THE MOVE, asserted on the rendered strip rather than on SECTIONS — the map being
      # right was never in question; what was wrong was a URL that disagreed with it.
      { suppliers_path => "Inventory", locations_path => "Inventory" }.each do |path, section|
        get path
        assert_select "header.strip a.strip-place[aria-current=page]", 1 do |links|
          assert_equal section, links.first.text.strip, "#{path} lights the wrong place"
        end
      end
    end

    # SHELVES IS A SETTINGS PAGE, AND LIGHTS NO PLACE. The second assertion is the half that catches
    # the page still lighting the Library (3D models) — which is what it did while it lived at
    # /models/shelves; its own row in the Settings column is the first.
    test "the shelves page lights its Settings row, not the Library" do
      get settings_shelves_path
      assert_select "aside.column .column-row[aria-current=page]", count: 1, text: "Shelves"
      assert_select "header.strip a.strip-place[aria-current=page]", 0
    end
  end
end
