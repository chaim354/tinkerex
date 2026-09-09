require "test_helper"
require "support/public_fixture"

module Web
  # STAGE 4, S4-4 (story 5.1): the maker's own preview of their public page, at ANY visibility.
  #
  # A SESSION-AUTHED ROUTE IN THE PRIVATE NAMESPACE (spec §7). Public::BaseController is untouched:
  # it still 404s a private project to everyone including its owner, and this page reaches the same
  # partials over the same Maker::PublicProject without going through it.
  class ProjectPreviewTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user, visibility: "private")
      @project = @f[:project]
      sign_in_as(@user)
    end

    test "a private project previews for its owner, inside the app shell, behind a banner" do
      get preview_project_path(@project)

      assert_response :success
      assert_select ".preview-banner", /Not published/
      assert_select "aside.rail"
      assert_select "nav.tabbar"
      assert_select ".public-files"
      # ONE breadcrumb landmark, the visitor's own (`@ada / Desk Lamp`). The shell's topbar yields a
      # `content_for :crumbs` on the signed-in branch, which the public page never takes — so a
      # crumbs block in preview.html.erb rendered a SECOND `nav.breadcrumb` with the same accessible
      # name above the first (measured in review: two on the preview, one on the public page).
      assert_select "nav.breadcrumb", count: 1
    end

    test "a private project's file link on the preview is a 404 for its owner, as it is for everyone" do
      # Decision 4: the preview keeps the VISITOR's urls, dead for a private project. The public
      # page's 404 is pinned by public_project_test; this pins the FILE route's, as the signed-in
      # owner, which is the link a maker will click on their own preview.
      get public_file_path("ada", @project.slug, @f[:base].node_id)

      assert_response :not_found
    end

    test "the same project is still a 404 on the public route, to its owner too" do
      get public_project_path("ada", @project.slug)

      assert_response :not_found
    end

    test "the preview's file links are the PUBLIC urls, byte for byte what a visitor would get" do
      get preview_project_path(@project)

      assert_select "a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id)
    end

    # THE FOLDER PANELS ARE PART OF "what a visitor sees" (2026-09-08, folder panels; spec §5), so
    # the preview renders them through the SAME public/projects/_folder_panel — the whole reason the
    # page body was extracted (its header: two templates claiming to show a visitor's page are a
    # pair that drifts, invisibly, until a maker publishes something the preview never showed them).
    # This is also the one place the partial renders under a SESSION-AUTHED controller, where a
    # `current_user` or a private route helper in it would work rather than raise.
    test "the preview renders the same folder panels, with the visitor's own links" do
      get preview_project_path(@project)

      assert_equal %w[firmware models photos], css_select("section.folder-panel h2").map(&:text)
      assert_select "section.folder-panel .public-tiles a[href=?]",
                    public_file_view_path("ada", @project.slug, @f[:base].node_id)
      assert_no_private_urls
    end

    test "a published project's banner says so and names the URL" do
      @project.update!(visibility: "public")

      get preview_project_path(@project)

      # The LISTED arm's own sentence, not /Published/ — that also matches "Published as unlisted",
      # so swapping the two arms' sentences would have stayed green.
      assert_select ".preview-banner", /Published: it is listed at/
      assert_select ".preview-banner a[href=?]", public_project_path("ada", @project.slug)
    end

    test "an unlisted project's preview carries the token on every link, as the public page does" do
      @project.update!(visibility: "unlisted")

      get preview_project_path(@project)

      assert_select ".preview-banner", /Published as unlisted/
      assert_select "a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id,
                                                  k: @project.reload.unlisted_token)
    end

    test "with no handle there is no URL to preview, and the refusal says where to get one" do
      @project.update!(visibility: "private")
      @user.update!(handle: nil)

      get preview_project_path(@project)

      assert_redirected_to project_path(@project)
      assert_match(/handle/i, flash[:alert])
    end

    test "another maker's project is a 404" do
      other = make_owner!(handle: "bob")
      theirs = other.maker_projects.create!(name: "Theirs")

      get preview_project_path(theirs)

      assert_response :not_found
    end
  end
end
