require "test_helper"

module Web
  # THE THREE REFERENCE PAGES MOVED TO THE SECTIONS THEY SERVE (2026-09-10). They lived at
  # `/settings/*` while `ShellHelper::SECTIONS` lit Models and Inventory for them, so clicking
  # Settings landed a maker on a page where Settings went dark and another rail item was
  # highlighted. The map was not the thing that was wrong; the URLs were.
  #
  # TWO THINGS HERE FAIL SILENTLY AND THAT IS WHY THIS FILE EXISTS:
  #
  #   1. THE SHADOWING. `/models/shelves` is a static segment under a resourceful path, so if
  #      `resources :models` is declared FIRST it matches as `models#show id=shelves` — a 404 on a
  #      page that exists. That is exactly what happened when these were moved and left below their
  #      parents, and nothing about the route file looks wrong when it does.
  #   2. THE REDIRECTS. A 301 that quietly stops being declared costs a maker their bookmarks, and
  #      no other test in the suite visits the old paths — they would simply 404 with nobody asking.
  class MovedReferencePagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "moved@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "each page lives under the section it serves and renders there" do
      { "/models/shelves" => shelves_path,
        "/inventory/suppliers" => suppliers_path,
        "/inventory/locations" => locations_path }.each do |want, got|
        assert_equal want, got, "the helper no longer points at the section it serves"
        get got
        # NOT MERELY ROUTABLE — RENDERED. A shadowed path routes perfectly well to the wrong
        # controller; only the response says which one answered.
        assert_response :success, "#{want} did not render — is it shadowed by its parent's :id route?"
      end
    end

    test "the old settings paths still redirect, permanently" do
      { "/settings/shelves" => "/models/shelves",
        "/settings/suppliers" => "/inventory/suppliers",
        "/settings/locations" => "/inventory/locations" }.each do |old, want|
        get old
        assert_response :moved_permanently, "#{old} stopped redirecting — that is a maker's bookmark"
        assert_equal want, response.headers["Location"].sub(%r{\Ahttps?://[^/]+}, "")
      end
    end

    test "the rail lights the section each page serves, and the URL now agrees with it" do
      # THE POINT OF THE MOVE, asserted on the rendered rail rather than on SECTIONS — the map being
      # right was never in question; what was wrong was a URL that disagreed with it.
      { shelves_path => "Models", suppliers_path => "Inventory", locations_path => "Inventory" }
        .each do |path, section|
          get path
          assert_select "aside.rail a.rail-link[aria-current=page]", 1 do |links|
            assert_equal section, links.first.text.strip,
                         "#{path} lights the wrong rail item"
          end
        end
    end
  end
end
