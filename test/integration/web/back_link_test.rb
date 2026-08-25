require "test_helper"

module Web
  # The file page's "Back" button. It used to be `link_to "Back", files_path` — a link to the
  # library root wearing the label of a back button, which dropped the folder, the type filter and
  # the project you came from on every single visit.
  #
  # BACKEND-NEUTRAL: nothing here touches the port. The button is rendered from the request's own
  # referer, so bare `nodes` rows are enough.
  class BackLinkTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
      @user = User.create!(email: "back-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      @user.nodes.create!(node_id: "n-part", name: "part.stl", kind: "file",
                          parent_node_id: "dir-cad", mtime: 1_000_000_000, size: 5)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def back_href
      css_select(".page-actions a.btn.ghost").first&.[]("href")
    end

    test "Back returns to the folder the file was opened from" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => files_url(folder: "dir-cad") }
      assert_equal files_path(folder: "dir-cad"), back_href
    end

    test "Back keeps a type filter" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => files_url(ext: "stl", view: "grid") }
      assert_equal files_path(ext: "stl", view: "grid"), back_href
    end

    # THE COMPLAINT IN ONE LINE: a file opened from a project's Files panel used to walk the user
    # out of the project entirely.
    test "Back returns to a project, not to the library" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get file_path("n-part"), headers: { "HTTP_REFERER" => project_url(project) }
      assert_equal project_path(project), back_href
    end

    test "no referer falls back to the library root, exactly as before" do
      get file_path("n-part")
      assert_equal files_path, back_href
    end

    # NOT A CURIOSITY — adding a note, deleting a note and resolving a move conflict all redirect
    # back to this same page, so without the self-reference guard the button would point at the
    # page it is on and read as broken.
    test "a referer equal to this page falls back rather than pointing at itself" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => file_url("n-part") }
      assert_equal files_path, back_href
    end

    # THE ONLY SECURITY PROPERTY THIS FEATURE HAS TO CARRY. The referer is a client-supplied
    # header, so an attacker controls it completely; what stops it becoming an open redirect is
    # that the host is COMPARED and then DISCARDED — only a root-relative path ever reaches href.
    test "a cross-origin referer is dropped, never rewritten into the link" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => "https://evil.example.com/files?x=1" }
      assert_equal files_path, back_href
      assert_no_match(/evil\.example\.com/, response.body)
    end

    # A host that merely STARTS with ours ("example.com.evil.test") must not pass. A `start_with?`
    # or `include?` spelling of the origin check is the classic way this guard is written wrong,
    # and it looks identical from the outside until someone registers the domain.
    test "a lookalike host is not treated as same-origin" do
      get file_path("n-part"),
          headers: { "HTTP_REFERER" => "http://#{request_host}.evil.test/files?folder=dir-cad" }
      assert_equal files_path, back_href
    end

    test "a malformed referer degrades to the fallback rather than 500ing the page" do
      get file_path("n-part"), headers: { "HTTP_REFERER" => "ht!tp://[not a url" }
      assert_response :success
      assert_equal files_path, back_href
    end

    private

    # The host the integration session actually issues requests to, so the lookalike above is
    # built from it rather than from a literal that could stop matching.
    def request_host = URI.parse(files_url).host
  end
end
