require "test_helper"
require "support/public_fixture"

module Web
  # THE SANDBOX DOOR (2026-11-19, embedded files; SandboxController, Maker::HtmlSandbox,
  # docs/invariants/files-preview.md "The sandbox door"). An HTML file from the library is served to
  # RUN, under an enforcing CSP `sandbox` policy that never grants `allow-same-origin`, with a signed
  # token as its only credential, and its relative URLs resolved inside its own folder.
  #
  # PINNED TO SHARE ON EVERY LEG (markdown_file_page_test.rb's reason): the door reads REAL BYTES
  # through the port, and only share has bytes behind a `create_node!` fixture.
  class SandboxTest < ActionDispatch::IntegrationTest
    include PublicFixture

    VIEWER = <<~HTML.freeze
      <!doctype html><title>Case</title><script src="app.js"></script><img src="img/plate.png">
    HTML

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "maker-#{SecureRandom.hex(3)}")
      @outer = dir!("pc case", nil)
      @folder = dir!("viewer", @outer)
      @html = file!("walnut case.html", @folder, VIEWER)
      @js = file!("app.js", @folder, "document.title = 'ran'")
      @png = file!("plate.png", dir!("img", @folder), "PNG")
      @outside = file!("secret.txt", @outer, "not yours")
      @dotfile = file!(".env", @folder, "SECRET=1")
      @git = file!("config", dir!(".git", @folder), "[core]")
    end

    def dir!(name, parent)
      create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "dir",
                          parent_node_id: parent&.node_id, mtime: 1, size: 0)
    end

    # A content_hash, or the port reports no content and the door answers 404.
    def file!(name, parent, body)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent&.node_id,
                                 mtime: 1, size: body.bytesize, content_hash: Digest::SHA256.hexdigest(body))
      @root.join(node.storage_path).binwrite(body)
      node
    end

    def token(node = @html, project: nil) = Maker::HtmlSandbox.token_for(owner: @user, node:, project:)

    def sandbox_directive = response.headers["Content-Security-Policy"].to_s

    test "the HTML file runs sandboxed: an enforcing policy with no allow-same-origin, and no Referer" do
      get sandbox_path(token, @html.name)

      assert_response :success
      assert_equal VIEWER, response.body
      assert_equal "text/html", response.media_type
      # ENFORCING: browsers ignore `sandbox` in a report-only header, so the one that matters is the
      # plain header — and the app's own report-only policy is off here.
      assert_match(/\Asandbox /, sandbox_directive)
      assert_includes sandbox_directive.split, "allow-scripts"
      assert_not_includes sandbox_directive, "allow-same-origin"
      assert_nil response.headers["Content-Security-Policy-Report-Only"]
      assert_equal "no-referrer", response.headers["Referrer-Policy"]
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_match(/\bprivate\b/, response.headers["Cache-Control"])
      assert_no_match(/\bpublic\b/, response.headers["Cache-Control"])
    end

    test "no session: the door works signed out and sets no cookie" do
      get sandbox_path(token, @html.name)

      assert_response :success
      assert_nil response.headers["Set-Cookie"], "a sandbox response must never carry a cookie"
    end

    test "a file beside it and one in a folder below it are served, sandboxed too" do
      get sandbox_path(token, "app.js")
      assert_response :success
      assert_equal "document.title = 'ran'", response.body
      assert_match(/\Asandbox /, sandbox_directive)

      get sandbox_path(token, "img/plate.png")
      assert_response :success
      assert_equal "PNG", response.body
    end

    test "nothing above the HTML file's folder, no dot-segment, no dot-file, no .git" do
      tok = token
      # (`img//plate.png` is not here: the router collapses the double slash before this door sees it.)
      [ "../secret.txt", "img/../../secret.txt", ".env", ".git/config", "missing.js" ].each do |path|
        get "/sandbox/#{tok}/#{path}"
        assert_response :not_found, "#{path.inspect} must be refused"
      end
      # A REFUSAL CARRIES NO POLICY OF THE APP'S EITHER: `content_security_policy false` keeps the
      # global report-only header (and the session-reading nonce behind it) off the answers that set
      # no sandbox header of their own.
      assert_nil response.headers["Content-Security-Policy-Report-Only"]
      assert_nil response.headers["Set-Cookie"]
    end

    test "a forged, foreign or expired token is a 404" do
      get sandbox_path("#{token}x", @html.name)
      assert_response :not_found

      # A token for a file that is not HTML names no page to run.
      get sandbox_path(token(@js), "app.js")
      assert_response :not_found

      tok = token
      travel Maker::HtmlSandbox::TTL + 1.minute do
        get sandbox_path(tok, @html.name)
        assert_response :not_found
      end
    end

    test "a token stops working when its HTML file is deleted" do
      tok = token
      @html.update!(deleted: true)

      get sandbox_path(tok, "app.js")
      assert_response :not_found
    end

    test "an over-cap file is refused before anything is read" do
      @js.update!(size: Maker::HtmlSandbox::MAX_BYTES + 1)

      get sandbox_path(token, "app.js")
      assert_response :content_too_large
    end

    test "the content token is the ETag, so an unchanged file reloads as a 304" do
      get sandbox_path(token, @html.name)
      etag = response.headers["ETag"]
      assert etag.present?

      get sandbox_path(token, @html.name), headers: { "If-None-Match" => etag }
      assert_response :not_modified
    end

    test "a public token re-asks the project: published, and permitted for every file" do
      project = @user.maker_projects.create!(name: "PC Case", visibility: "public")
      folder = make_project_folder!(@user, project)
      viewer = dir!("viewer", folder)
      html = file!("case.html", viewer, VIEWER)
      file!("app.js", viewer, "ok")
      tok = token(html, project:)

      get sandbox_path(tok, "case.html")
      assert_response :success
      get sandbox_path(tok, "app.js")
      assert_response :success

      # A token naming a project that does not claim the file serves nothing.
      get sandbox_path(token(@html, project:), @html.name)
      assert_response :not_found

      # AN HTML FILE THE PROJECT HOLDS BY ATTACHMENT, from outside its folder, is public — and the files
      # beside it are NOT, so the page runs and its neighbours stay home. This is the one shape that
      # reaches `resolve`'s own `permits?` (inside the folder, ancestry permits everything the dot rule
      # has not already refused).
      project.file_attachments.create!(user: @user, node_id: @html.node_id, role: "code", position: 0)
      attached = token(@html, project:)
      get sandbox_path(attached, @html.name)
      assert_response :success
      get sandbox_path(attached, "app.js")
      assert_response :not_found

      # Unpublishing closes the door on the next request, not when the token expires.
      project.update!(visibility: "private")
      get sandbox_path(tok, "case.html")
      assert_response :not_found
    end
  end
end
