require "test_helper"

module Web
  # STAGE 4, S4-4 (stories 5.2, 5.8): the Publish panel on the project page — the ONE place
  # visibility and licence are set, with the meanings spelled out, the handle claimable inline, the
  # URL copyable, and the unlisted link rotatable.
  #
  # Field names are asserted as RENDERED (§14d): the panel's form is `scope: :project` over a
  # NAMESPACED model, so without it the radios would be named `maker_project[...]` and every save
  # would silently drop them; the inline claim is `scope: :user` for the same reason. The three
  # rendered-form tests that lived in project_publishing_form_test.rb moved here with the controls.
  class PublishingTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "publish-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # --- the panel -----------------------------------------------------------------------------

    test "with a handle the panel offers three visibility rows with their meanings, under the name the controller permits" do
      @user.update!(handle: "chaim")

      get project_path(@project)

      assert_select "section.publish-panel#publish" do
        assert_select "input[type=radio][name=?]", "project[visibility]", 3
        assert_select "input[type=radio][name=?][value=private][checked=checked]", "project[visibility]"
        assert_select ".publish-option", text: /only you/i
        assert_select ".publish-option", text: /anyone with the link/i
        assert_select ".publish-option", text: /listed at \/explore/i
        assert_select "select[name=?]", "project[license]" do
          assert_select "option[value=?]", "MIT"
          assert_select "option[value=?]", "CERN-OHL-S-2.0"
        end
        assert_select "input[type=hidden][name=return_to][value=project]"
      end
    end

    test "with a handle the panel carries no handle form" do
      @user.update!(handle: "chaim")

      get project_path(@project)

      assert_select "section.publish-panel form[action=?]", settings_handle_path, 0
      assert_select "section.publish-panel input[name=?]", "user[handle]", 0
    end

    # TWO DOORS SINCE SLICE 6, AND BOTH ARE ANCHORS: the head's Publish link and the ⋯ menu's
    # Publish settings.
    test "the page head links to the panel" do
      get project_path(@project)
      assert_select ".page-head a.publish-link[href='#publish']", 1
      assert_select ".page-head details.project-menu a.menu-item[href='#publish']", { count: 1, text: "Publish settings" }
    end

    test "with no handle the panel claims one inline and offers no visibility rows" do
      get project_path(@project)

      assert_select "section.publish-panel form[action=?]", settings_handle_path do
        assert_select "input[name=?]", "user[handle]"
        assert_select "input[type=hidden][name=project_id][value=?]", @project.slug
      end
      assert_select "section.publish-panel input[type=radio][name=?]", "project[visibility]", 0
    end

    test "a published project shows its URL with a copy control" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "public")

      get project_path(@project)

      url = public_project_url(@project.user.handle, @project.slug)
      assert_select ".publish-url[data-controller~=?][data-copy-text-value=?]", "copy", url
      assert_select ".publish-url button[data-action=?]", "copy#copy", text: "Copy"
      assert_select ".publish-panel a[href=?]", preview_project_path(@project), text: "Preview"
    end

    test "an unlisted project shows the token link with copy and a New link button" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "unlisted")

      get project_path(@project)

      url = public_project_url("chaim", @project.slug, k: @project.reload.unlisted_token)
      assert_select ".publish-unlisted[data-controller~=?][data-copy-text-value=?]", "copy", url
      assert_select "form[action=?]", project_unlisted_token_path(@project)
    end

    # --- the save ------------------------------------------------------------------------------

    test "publishing names the URL and what became downloadable" do
      @user.update!(handle: "chaim")

      patch project_path(@project), params: { project: { visibility: "public" }, return_to: "project" }

      assert_redirected_to project_path(@project)
      assert_match %r{/u/chaim/desk-lamp}, flash[:notice]
      assert_match(/downloadable/, flash[:notice])
    end

    test "unpublishing says the public page is gone" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "public")

      patch project_path(@project), params: { project: { visibility: "private" }, return_to: "project" }

      assert_match(/private again/, flash[:notice])
    end

    test "a change that is not a visibility change keeps the old wording" do
      patch project_path(@project), params: { project: { name: "Lamp" } }
      assert_equal "Project updated.", flash[:notice]
    end

    test "a refusal from the panel lands back on the project page, not on the edit form" do
      patch project_path(@project), params: { project: { visibility: "public" }, return_to: "project" }

      assert_redirected_to project_path(@project)
      assert_match(/handle/i, flash[:alert])
      assert_equal "private", @project.reload.visibility
    end

    # --- the unlisted token --------------------------------------------------------------------

    test "New link mints a new token and says the old one stopped working" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "unlisted")
      before = @project.reload.unlisted_token

      post project_unlisted_token_path(@project)

      assert_redirected_to project_path(@project)
      assert_not_equal before, @project.reload.unlisted_token
      assert_match(/\A\h{32}\z/, @project.unlisted_token)
      assert_match(/no longer work/, flash[:notice])
    end

    test "the old link stops working the moment it is rotated" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "unlisted")
      old = @project.reload.unlisted_token

      post project_unlisted_token_path(@project)
      delete destroy_user_session_path

      get public_project_path("chaim", @project.slug, k: old)
      assert_response :not_found
      get public_project_path("chaim", @project.slug, k: @project.reload.unlisted_token)
      assert_response :success
    end

    test "a project that is not unlisted has no link to rotate" do
      @user.update!(handle: "chaim")

      post project_unlisted_token_path(@project)

      assert_redirected_to project_path(@project)
      assert_match(/unlisted/, flash[:alert])
    end

    # --- the inline handle claim ---------------------------------------------------------------

    test "claiming a handle from the panel returns to the project" do
      patch settings_handle_path, params: { user: { handle: "chaim" }, project_id: @project.slug }

      assert_redirected_to project_path(@project)
      assert_equal "chaim", @user.reload.handle
    end

    test "a refused claim from the panel also returns to the project" do
      patch settings_handle_path, params: { user: { handle: "x" }, project_id: @project.slug }

      assert_redirected_to project_path(@project)
      assert_match(/Handle/, flash[:alert])
    end

    test "a hash-shaped project_id cannot 500 a claim that already saved" do
      # FOUND IN REVIEW: `params[:project_id]` reached `find_by(slug:)` untyped, so `project_id[a]=1`
      # raised TypeError from return_path — AFTER `current_user.save` had committed the handle. The
      # maker saw a 500 for a claim that in fact succeeded.
      patch settings_handle_path, params: { user: { handle: "chaim" }, project_id: { a: "1" } }

      assert_redirected_to edit_user_registration_path
      assert_equal "chaim", @user.reload.handle
    end

    test "each Copy button sits in a copy controller that also marks the value as its selection fallback" do
      # copy_controller.js's last resort (no clipboard API, execCommand refused — the plain-http
      # self-hosted case its header is written for) SELECTS the `source` target so the maker can
      # copy by hand. A button-only mount has no source and fails silently there.
      @user.update!(handle: "chaim")
      @project.update!(visibility: "public")
      get project_path(@project)
      assert_select ".publish-url[data-controller~=copy] .mono[data-copy-target=source]", 1

      @project.update!(visibility: "unlisted")
      get project_path(@project)
      assert_select ".publish-unlisted[data-controller~=copy] .mono[data-copy-target=source]", 1
    end

    test "the warning names the project's ACTUAL folder, not a path rebuilt from its slug" do
      # A discovered project (Maker::ProjectDiscovery) keeps the folder's own name and gets a
      # slugified slug: folder `Projects/Desk Lamp`, slug `desk-lamp`. Permission is granted from
      # the folder NODE (Maker::PublicProject#permits?), so the sentence must name that folder.
      @user.update!(handle: "chaim")
      folder = project_folder_rows!(@user, @project)
      folder.update!(name: "Desk Lamp")

      get project_path(@project)

      assert_select ".publish-warning .mono", text: "Projects/Desk Lamp"
      assert_select ".publish-warning .mono", text: "Projects/desk-lamp", count: 0
      assert_select ".publish-warning", /attached to the project/
    end

    test "another maker's slug in project_id falls back to the account page" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      patch settings_handle_path, params: { user: { handle: "chaim" }, project_id: theirs.slug }

      assert_redirected_to edit_user_registration_path
    end
  end
end
