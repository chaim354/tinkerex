require "test_helper"
require "support/public_fixture"

module Web
  # STAGE 3, S3-4: /explore and /u/:handle — the two LIST surfaces.
  #
  # ONE RULE CARRIES THE WHOLE SUITE: a list shows `publicly_listed` projects, never `published`.
  # The two scopes differ by exactly the unlisted state, whose entire premise is that it has a URL
  # and is not advertised — so the substitution is silent, plausible, and the thing to
  # mutation-check. It is asserted on the project list AND on the tag chips, because a chip
  # counting an unlisted project's tag discloses that the project exists just as loudly.
  #
  # NO SHARE PIN AND NO FOLDER HERE, deliberately: neither list touches the port at all (no
  # listing, no README, no thumbnail), so these run on the ambient backend on all three legs.
  class PublicExploreTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @ada = make_owner!(handle: "ada")
      @bob = make_owner!(handle: "bob")

      @public_a  = publish!(@ada, "Desk Lamp",  "public",   tags: "lamp, laser", at: 3.days.ago)
      @public_b  = publish!(@bob, "Bike Rack",  "public",   tags: "steel",       at: 1.day.ago)
      @unlisted  = publish!(@ada, "Secret Rig", "unlisted", tags: "hidden",      at: 2.days.ago)
      @private_p = publish!(@ada, "Napkin Idea", "private", tags: "hidden",      at: Time.current)
    end

    def publish!(user, name, visibility, tags:, at: Time.current)
      project = user.maker_projects.create!(name:, visibility:, tag_list: tags,
                                            description: "#{name} description")
      project.update_column(:updated_at, at)
      project.reload
    end

    # --- /explore ---------------------------------------------------------------------

    test "explore lists public projects only, newest first" do
      get public_explore_path

      assert_response :success
      names = css_select(".project-card-grid .card-title a").map(&:text)
      assert_equal [ "Bike Rack", "Desk Lamp" ], names,
                   "an unlisted or private project must never appear on a list"
    end

    test "explore is cross-user and links each card to its own maker" do
      get public_explore_path

      assert_select ".project-card a[href=?]", public_project_path("ada", @public_a.slug)
      assert_select ".project-card a[href=?]", public_project_path("bob", @public_b.slug)
      assert_select ".project-card a[href=?]", public_user_path("bob"), text: "@bob"
    end

    test "?tag= filters to the projects wearing it" do
      get public_explore_path(tag: "lamp")

      assert_equal [ "Desk Lamp" ], css_select(".project-card-grid .card-title a").map(&:text)
      assert_select ".explore-chips a.tag-chip.active", text: /\Alamp/
      assert_select ".explore-chips a[href=?]", public_explore_path, text: "All"
    end

    test "an unknown tag filters to nothing rather than erroring" do
      get public_explore_path(tag: "nosuchtag")

      assert_response :success
      assert_select ".empty", text: "No public projects yet."
    end

    test "the chips count public projects only" do
      get public_explore_path

      chips = css_select(".explore-chips a.tag-chip").map(&:text)
      assert_includes chips, "lamp (1)"
      assert_includes chips, "steel (1)"
      assert chips.none? { |c| c.start_with?("hidden") },
             "`hidden` is worn only by an unlisted and a private project: a chip discloses both"
    end

    test "a second public project sharing a tag raises its count" do
      publish!(@bob, "Shop Lamp", "public", tags: "lamp")
      get public_explore_path

      assert_includes css_select(".explore-chips a.tag-chip").map(&:text), "lamp (2)"
    end

    test "explore needs no session" do
      get public_explore_path

      assert_response :success
      assert_select "aside.rail", false
      assert_select "nav.tabbar", false
    end

    # --- /u/:handle --------------------------------------------------------------------

    test "a maker's page lists their public projects only" do
      get public_user_path("ada")

      assert_response :success
      assert_select "h1", text: "@ada"
      assert_equal [ "Desk Lamp" ], css_select(".project-card-grid .card-title a").map(&:text)
      assert_select ".project-card a[href=?]", public_project_path("bob", @public_b.slug), false,
                    "this is ada's page, not everyone's"
    end

    test "a maker's page counts what it lists" do
      get public_user_path("ada")
      assert_select ".page-head .mono.muted", text: "1 public project"
    end

    test "a handle with no public projects says so" do
      get public_user_path("bob")
      @public_b.update!(visibility: "private")

      get public_user_path("bob")
      assert_select ".empty", text: "No public projects yet."
    end

    test "an unknown handle is a 404" do
      get public_user_path("nobody")
      assert_response :not_found
    end

    test "a handle is matched case-insensitively" do
      get public_user_path("ADA")
      assert_response :success
      assert_select "h1", text: "@ada"
    end

    # --- Stage 4, S4-5: the cover slot and the visitor's header ---------------------------

    # NO COVER FIXTURE HERE, AND THAT IS THIS SUITE'S OWN RULE, NOT AN OMISSION: a ready cover needs
    # real bytes behind it, which means `use_fresh_share_library!`, which is exactly the share pin
    # this file's header refuses. The READY branch is asserted in public_project_test.rb, which
    # already owns a share library. What belongs here is the branch that needs nothing — and the
    # absence of the poll, which no share-pinned test would notice.
    test "a public card carries a cover slot, with the placeholder when there is no cover and never a poll" do
      get public_explore_path

      assert_response :success
      assert_select ".project-card .card-cover", minimum: 1
      assert_select ".project-card .project-thumb-empty", minimum: 1
      # /files/thumbnails is session-authed, so a visitor's spinner has nothing that could ever
      # resolve it. The controller must not be on this page at all.
      assert_select "[data-controller=?]", "thumbs", 0
    end

    test "the anonymous header names the site and, on a maker's page, the maker" do
      get public_explore_path
      assert_select "header.public-header a[href=?]", public_explore_path
      assert_select "header.public-header p.public-intro"

      get public_user_path("ada")
      assert_select "header.public-header a[href=?]", public_user_path("ada")
      assert_select "header.public-header p.public-intro", 0
    end

    test "a signed-in visitor still gets the visitor's header and no rail" do
      sign_in_as(@ada)
      get public_explore_path

      assert_select "header.public-header", 1
      assert_select "aside.rail", 0
    end

    # DEVISE'S PAGES SHARE THE ANONYMOUS BRANCH AND ARE A DIFFERENT SURFACE: a sign-in form under an
    # Explore link reads as a site nav on a page that has none.
    test "the sign-in page gets no public header" do
      get new_user_session_path

      assert_response :success
      assert_select "header.public-header", 0
    end
  end
end
