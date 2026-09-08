require "test_helper"
require "support/public_fixture"

module Web
  # /u/:handle IS BOUNDED (hardening, 2026-09-08; tinkerex#279).
  #
  # The list used to render every public project a maker had, to anyone, in one anonymous GET —
  # one cover stat and one card per project, with nothing to stop it. This suite pins the bound
  # (a page is at most PAGE cards), the head that must keep telling the truth about the TOTAL
  # anyway, and every way a `page` param arrives wrong — junk, zero, negative, and past the end.
  #
  # NO SHARE PIN AND NO FOLDER HERE, deliberately — public_explore_test.rb's rule, for its reason:
  # a project with no attachments has no cover node, so `permitted_cover_ids` answers {} and
  # `ThumbnailMap.for` never reaches the port. These run on the ambient backend on all three legs.
  # (A project needs no folder to be published; `page_query_budget_test.rb`'s own seed creates them
  # exactly this way.)
  class PublicUserPageTest < ActionDispatch::IntegrationTest
    include PublicFixture

    PAGE = Public::UsersController::PAGE
    NEWEST = Time.zone.local(2026, 5, 1, 12, 0, 0)

    setup do
      @ada = make_owner!(handle: "ada")
      # PAGE + 1 projects: the smallest library that has a second page, so page 2 carrying exactly
      # one card is itself the assertion that the limit is PAGE and not PAGE + 1.
      #
      # "Project 01" is the NEWEST and "Project 61" the OLDEST, one minute apart, so the rendered
      # order is the name order and an off-by-one in the offset reads as a wrong name rather than
      # as a count that still happens to be 60.
      (PAGE + 1).times { |i| public_project!("Project %02d" % (i + 1), at: NEWEST - i.minutes) }
      # AN UNLISTED PROJECT, NEWER THAN EVERY PUBLIC ONE. Its whole premise is that it has a URL and
      # is not advertised, so `published` for `publicly_listed` in the controller must be caught —
      # and being the newest row is what makes that mutation land on the FIRST card of page 1
      # instead of somewhere in the middle of a 61-name list.
      public_project!("Secret Rig", at: NEWEST + 1.minute, visibility: "unlisted")
    end

    def public_project!(name, at:, visibility: "public", owner: @ada)
      project = owner.maker_projects.create!(name:, visibility:, status: "active")
      project.update_column(:updated_at, at)
      project.reload
    end

    def titles = css_select(".project-card-grid .card-title a").map(&:text)

    # --- The bound -----------------------------------------------------------------------

    test "page 1 carries a full page of the newest projects and no more" do
      get public_user_path("ada")

      assert_response :success
      assert_select ".project-card", count: PAGE
      assert_equal "Project 01", titles.first, "newest first"
      assert_equal "Project 60", titles.last
    end

    test "page 2 carries the remainder, oldest last" do
      get public_user_path("ada", page: 2)

      assert_response :success
      assert_select ".project-card", count: 1
      assert_equal [ "Project 61" ], titles
    end

    test "the head counts every public project, not the page" do
      get public_user_path("ada")
      assert_select ".page-head .mono.muted", text: "61 public projects"

      get public_user_path("ada", page: 2)
      # THE BRACES ARE REQUIRED, not style: `assert_select` reads its arguments as
      # (selector, substitutions…, comparator, message), so an unbraced `text:` followed by a
      # message string is one hash literal missing a value — and where the selector carries a `?`,
      # a bare trailing message is silently taken as the TEXT to compare against.
      assert_select ".page-head .mono.muted", { text: "61 public projects" },
                    "the total is the same fact on every page"
    end

    # --- The pager -----------------------------------------------------------------------

    test "page 1 offers Older and nothing newer" do
      get public_user_path("ada")

      assert_select ".pager-status", text: /Page 1 of 2/
      assert_select ".pager-next[href=?]", public_user_path("ada", page: 2)
      assert_select ".pager-prev", false, "page 1 has no newer page to link"
    end

    test "page 2 offers Newer, and page 1 keeps its bare URL" do
      get public_user_path("ada", page: 2)

      assert_select ".pager-status", text: /Page 2 of 2/
      assert_select ".pager-prev[href=?]", public_user_path("ada"), { count: 1 },
                    "page 1 is /u/:handle, never ?page=1: one page, one canonical URL"
      assert_select ".pager-next", false, "page 2 is the last"
    end

    test "a maker whose projects fit on one page gets no pager at all" do
      bob = make_owner!(handle: "bob")
      public_project!("Only One", at: NEWEST, owner: bob)

      get public_user_path("bob")

      assert_response :success
      assert_select ".project-card", count: 1
      assert_select ".pager", false
    end

    # --- The `page` param ----------------------------------------------------------------

    test "a page past the last is a 404" do
      get public_user_path("ada", page: 3)
      assert_response :not_found
    end

    test "an empty maker has one page, and page 2 of it is a 404" do
      make_owner!(handle: "cal")

      get public_user_path("cal")
      assert_response :success
      assert_select ".empty", text: "No public projects yet."
      assert_select ".pager", false

      get public_user_path("cal", page: 2)
      assert_response :not_found
    end

    test "a page that is not a positive integer reads as page 1" do
      [ "0", "-4", "abc", "", "1.5" ].each do |junk|
        get public_user_path("ada", page: junk)

        assert_response :success, "?page=#{junk.inspect} must render, not error"
        assert_select ".project-card", count: PAGE
        assert_equal "Project 01", titles.first, "?page=#{junk.inspect} must be page 1"
        assert_select ".pager-status", text: /Page 1 of 2/
      end
    end

    # NO TEST FOR THE `id: :desc` TIE-BREAK, AND THAT IS A MEASUREMENT RATHER THAN AN OMISSION. The
    # obvious guard — give all 61 projects one `updated_at`, then assert page 1 + page 2 hold 61
    # DISTINCT names — was written and mutation-checked here: with the tie-break REMOVED from
    # Public::UsersController it still passed, because SQLite answers equal sort keys in rowid order
    # and does so identically at both offsets. It is a guard that cannot fail on the backend this
    # suite runs on, which is the shape §15 refuses. The tie-break stays in the controller (its
    # comment carries the argument); what would catch its removal is a database free to reorder
    # equal keys, not an assertion here.

    # --- What a list may show -------------------------------------------------------------

    test "an unlisted project appears on no page and is counted on none" do
      names = []
      get public_user_path("ada")
      names += titles
      get public_user_path("ada", page: 2)
      names += titles

      assert_equal 61, names.size
      refute_includes names, "Secret Rig",
                      "`publicly_listed`, never `published`: an unlisted project is not advertised"
      assert_select ".page-head .mono.muted", text: "61 public projects"
    end
  end
end
