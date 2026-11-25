require "test_helper"

module Web
  # THE TOP BAR'S BACK (2026-11-24), the one Back button: on every signed-in page, at the far left.
  # A click steps back in the tab's own history (back_controller.js, driven in
  # test/system/topbar_back_test.rb); what is pinned here is the HREF, which a fresh tab, a bookmark
  # and a browser without JavaScript follow — ShellHelper#topbar_back_path.
  #
  # It replaced the file page's own Back, which sat at the right of the page head. That one's href
  # was `link_to "Back", files_path` before it was the referer, and the referer half of the story is
  # kept: ApplicationHelper#back_target_path still decides it, so its origin check is still what
  # stands between a client-supplied header and an href.
  #
  # BACKEND-NEUTRAL: nothing here touches the port. The link is rendered from the request's own
  # referer and the page's own breadcrumb, so bare `nodes` rows are enough.
  #
  # MUTATION-CHECKED (2026-11-24; each reverted, and the file re-run green after):
  #   1. `topbar_back_path` ignoring the referer: the folder, filter, project and one-Back tests red.
  #   2. `topbar_back_path` answering its target even when it is this page: the Recent test red.
  #   3. The link without `turbo_prefetch: "false"`: the prefetch test red.
  #   4. A Back put back in the file page's head: the no-Back test red, and with it
  #      file_page_test.rb's head test and file_page_copy_test.rb's button order.
  class TopbarBackTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
      @user = User.create!(email: "back-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "n-part", name: "part.stl", kind: "file",
                          parent_node_id: "dir-cad", mtime: 1_000_000_000, size: 5)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def back_link = css_select("header.topbar a.topbar-back").first
    def back_href = back_link&.[]("href")

    # The file's own folder, with the file selected: the last link of its breadcrumb.
    def up_from_part = files_path(folder: "dir-cad", selected: "n-part")

    test "every signed-in page carries exactly one Back, first in the top bar, named for a screen reader" do
      [ root_path, files_path, file_path("n-part"), projects_path, tools_path ].each do |path|
        get path, headers: { "HTTP_REFERER" => help_url }
        assert_response :success
        assert_select "header.topbar > a.topbar-back[aria-label='Back'][title='Back']", { count: 1 }, path
        assert_select "header.topbar > :first-child.topbar-back", { count: 1 }, "Back is the bar's first control on #{path}"
        assert_equal help_path, back_href, path
      end
    end

    # THE BUTTON THE OWNER ASKED TO HAVE MOVED. The file page's head held Download, Back and Delete at
    # its right; Back is the top bar's now, so the row is Download and Delete.
    test "the file page's own head holds no Back" do
      get file_path("n-part")
      assert_select ".page-actions a", text: "Back", count: 0
      assert_select ".page-actions a.btn", text: "Download", count: 1
    end

    test "Back returns to the folder the file was opened from" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => files_url(folder: "dir-cad") }
      assert_equal files_path(folder: "dir-cad"), back_href
    end

    test "Back keeps a type filter" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => files_url(ext: "stl", view: "grid") }
      assert_equal files_path(ext: "stl", view: "grid"), back_href
    end

    # THE ORIGINAL COMPLAINT IN ONE LINE: a file opened from a project's Files panel used to walk the
    # user out of the project entirely.
    test "Back returns to a project, not to the library" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get file_path("n-part"), headers: { "HTTP_REFERER" => project_url(project) }
      assert_equal project_path(project), back_href
    end

    # ONE LEVEL UP, FROM THE PAGE'S OWN BREADCRUMB. A page opened cold has no referer, and "the
    # library root" was the old answer for a file six folders deep. The breadcrumb's last link is the
    # page's parent place and every page with a breadcrumb already says it.
    test "no referer falls back to the breadcrumb's last link" do
      get file_path("n-part")
      assert_equal up_from_part, back_href
    end

    test "a page with no breadcrumb falls back to Recent" do
      get projects_path
      assert_equal root_path, back_href
      assert_nil back_link["aria-disabled"]
    end

    # RECENT, OPENED COLD, HAS NOWHERE TO POINT: its fallback is itself. Drawn disabled instead of as
    # a link to the page it is on; back_controller.js lifts that when the tab does have history.
    test "Recent with nothing behind it draws Back disabled" do
      get root_path
      assert_equal "true", back_link["aria-disabled"]
      get root_path, headers: { "HTTP_REFERER" => files_url }
      assert_nil back_link["aria-disabled"]
      assert_equal files_path, back_href
    end

    # NOT A CURIOSITY — adding a note, deleting a note and resolving a move conflict all redirect
    # back to this same page, so without the self-reference guard the button would point at the
    # page it is on and read as broken.
    test "a referer equal to this page falls back rather than pointing at itself" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => file_url("n-part") }
      assert_equal up_from_part, back_href
    end

    # THE ONLY SECURITY PROPERTY THIS FEATURE HAS TO CARRY. The referer is a client-supplied
    # header, so an attacker controls it completely; what stops it becoming an open redirect is
    # that the host is COMPARED and then DISCARDED — only a root-relative path ever reaches href.
    test "a cross-origin referer is dropped, never rewritten into the link" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => "https://evil.example.com/files?x=1" }
      assert_equal up_from_part, back_href
      assert_no_match(/evil\.example\.com/, response.body)
    end

    # A host that merely STARTS with ours ("example.com.evil.test") must not pass. A `start_with?`
    # or `include?` spelling of the origin check is the classic way this guard is written wrong,
    # and it looks identical from the outside until someone registers the domain.
    test "a lookalike host is not treated as same-origin" do
      get file_path("n-part"),
          headers: { "HTTP_REFERER" => "http://#{request_host}.evil.test/files?folder=dir-cad" }
      assert_equal up_from_part, back_href
    end

    test "a malformed referer degrades to the fallback rather than 500ing the page" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => "ht!tp://[not a url" }
      assert_response :success
      assert_equal up_from_part, back_href
    end

    # A hover would fetch the page behind this one, which the click then never loads (it steps back
    # in history), and a repository's commit and history pages run git on a GET.
    test "Back is never prefetched" do
      get file_path("n-part")
      assert_equal "false", back_link["data-turbo-prefetch"]
    end

    test "a signed-out page has no Back" do
      delete destroy_user_session_path
      get new_user_session_path
      assert_response :success
      assert_select ".topbar-back", count: 0
    end

    private

    # The host the integration session actually issues requests to, so the lookalike above is
    # built from it rather than from a literal that could stop matching.
    def request_host = URI.parse(files_url).host
  end
end
