require "test_helper"

module Web
  # A MARKDOWN FILE PAGE OFFERS A RENDERED VIEW (2026-11-02, the UX audit's D8). FilesController#show
  # reads the file once through the port and renders it with Maker::MarkdownFile — the README card's
  # renderer and its two link arms — behind a Rendered / Source toggle, Rendered pressed. Every other
  # text file, and a Markdown file that cannot be rendered, gets the source view alone.
  #
  # PINNED TO SHARE ON EVERY LEG (use_fresh_share_library!, readme_test.rb's reason): the page reads
  # REAL BYTES through the port, and a fixture built with `create_node!` has bytes behind it only on
  # share — on the s3 leg the stub bucket holds nothing, on chunk_remote there is no version. Rows
  # plus files, never `ensure_library_folder!`.
  class MarkdownFilePageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    README = <<~MD.freeze
      # Desk Lamp

      See [x](other.svg) for the outline, and [base](models/base.stl) for the printed part.

      ![y](plate.svg)

      A [dead link](missing.svg) stays as its words.

      <script>alert("raw")</script>

      <p onclick="evil()">clicked</p>
    MD

    # The house stub helper (library_unreachable_test.rb carries the same body; Minitest 6 has no
    # Object#stub). Replaces a SINGLETON method for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "md-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @folder = dir!("lamp", nil)
      @readme = file!("README.md", @folder, README)
      @other = file!("other.svg", @folder, "<svg/>")
      @plate = file!("plate.svg", @folder, "<svg/>")
      @base = file!("base.stl", dir!("models", @folder), "solid base")
    end

    def dir!(name, parent)
      create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "dir",
                          parent_node_id: parent&.node_id, mtime: 1, size: 0)
    end

    # `create_node!` writes a placeholder at the storage_path it computes; the real body goes over it
    # there, so the catalog and the disk agree about where the file is. A content_hash, because the
    # port reports no content without one and the page would render "No content yet.".
    def file!(name, parent, body)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent&.node_id,
                                 mtime: 1, size: body.bytesize, content_hash: Digest::SHA256.hexdigest(body))
      @root.join(node.storage_path).binwrite(body)
      node
    end

    test "a Markdown file page renders its prose, Rendered pressed and Source one press away" do
      get file_path(@readme.node_id)
      assert_response :success

      assert_select ".markdown-view .view-toggle[role=group]" do
        assert_select "button.toggle.active[aria-pressed=true][data-markdown-view-pane-param=rendered]", text: "Rendered"
        assert_select "button.toggle:not(.active)[aria-pressed=false][data-markdown-view-pane-param=source]", text: "Source"
      end
      assert_select ".markdown-rendered.markdown:not([hidden]) h1", text: "Desk Lamp"
      # THE SOURCE VIEW IS STILL THE SAME VIEWER, behind the toggle: a loose .md is editable, so it is
      # the editor, as it was before this view existed.
      assert_select ".markdown-source[hidden] .preview-code[data-controller=editor]", 1
    end

    test "relative links open the file's page, pictures load its bytes, and a dead link is its words" do
      get file_path(@readme.node_id)

      assert_select ".markdown-rendered a[href=?]", file_path(@other.node_id), text: "x"
      # A SUBFOLDER, as on the project's README card, whose index is the whole project folder.
      assert_select ".markdown-rendered a[href=?]", file_path(@base.node_id), text: "base"
      assert_select ".markdown-rendered img[src=?][alt=y]", blob_file_path(@plate.node_id)
      assert_select ".markdown-rendered a", text: "dead link", count: 0
      assert_select ".markdown-rendered p", text: /A dead link stays as its words\./
    end

    # THE LIBRARY ROOT IS A FOLDER TOO, whose id is nil: the walk beneath it must still run, or a root
    # file's links into subfolders become text while its links to siblings resolve (found in review).
    # Mutation-checked (2026-11-02): the old `while (id = queue.shift)` loop turns the `deep` line red.
    test "a file at the library root resolves links into its subfolders as well as to its siblings" do
      top = file!("top.stl", nil, "solid top")
      root = file!("ROOT.md", nil, "[top](top.stl) and [deep](lamp/models/base.stl)\n")
      get file_path(root.node_id)

      assert_select ".markdown-rendered a[href=?]", file_path(top.node_id), text: "top"
      assert_select ".markdown-rendered a[href=?]", file_path(@base.node_id), text: "deep"
    end

    # THE README CARD'S RULE (Maker::Markdown): a README is the maker's prose, never trusted markup.
    # A script goes WITH its text, an event handler goes, and the words around them stay.
    test "raw HTML is stripped the way the README card strips it" do
      get file_path(@readme.node_id)

      assert_select ".markdown-rendered script", count: 0
      assert_select ".markdown-rendered [onclick]", count: 0
      assert_select ".markdown-rendered p", text: "clicked"
      assert_no_match(/alert\(&quot;raw&quot;\)|alert\("raw"\)/, css_select(".markdown-rendered").to_s)
    end

    test "a plain text file has no toggle and no rendered view" do
      notes = file!("notes.txt", @folder, "# not a heading here\n")
      get file_path(notes.node_id)
      assert_response :success

      assert_select ".markdown-view", 0
      assert_select ".preview .view-toggle", 0
      assert_select ".markdown-rendered", 0
      assert_select ".preview .preview-code[data-controller=editor]", 1
    end

    # THE CATALOG'S SIZE GATES THE READ, the README card's rule: past the limit the port is never
    # asked, and the source view stands alone under a sentence saying why.
    test "a Markdown file over the limit is never read; the source view says why" do
      @readme.update_column(:size, Maker::MarkdownFile::LIMIT + 1)
      replacing(FileLayer.current, :read, ->(*) { raise "the port must not be read past the limit" }) do
        get file_path(@readme.node_id)
      end
      assert_response :success

      assert_select ".markdown-view", 0
      assert_select ".markdown-note", text: "Too large to render; showing the source."
      assert_select ".preview .preview-code", 1
    end

    # THE CATALOG CAN LAG THE STORE (a share file grown since the last scan), so the bytes are measured
    # too: a file the catalog calls small and the disk holds past the limit is read, and not rendered.
    test "a Markdown file the catalog calls small but whose bytes are over the limit is not rendered" do
      body = "# Grown\n\n#{'x' * Maker::MarkdownFile::LIMIT}\n"
      @root.join(@readme.storage_path).binwrite(body)
      assert_operator @readme.reload.size, :<=, Maker::MarkdownFile::LIMIT, "the catalog must say small here"

      get file_path(@readme.node_id)
      assert_response :success

      assert_select ".markdown-view", 0
      assert_select ".markdown-note", text: "Too large to render; showing the source."
      assert_select ".preview .preview-code", 1
    end

    # AN OUTAGE IS SAID, AND THE PAGE STAYS UP (Current.library_unreachable's rule): the source view,
    # the app's one sentence for it, and the layout's banner.
    test "a library the store cannot reach leaves the source view, the one sentence and the banner" do
      replacing(FileLayer.current, :read, ->(*) { raise FileLayer::FetchError, "share unmounted" }) do
        get file_path(@readme.node_id)
      end
      assert_response :success

      assert_select ".markdown-view", 0
      assert_select ".markdown-note", text: "Couldn't reach your library. Try again."
      assert_select ".library-unreachable", 1
      assert_select ".preview .preview-code", 1
    end

    # A FILE GONE SINCE THE STAT IS NOT AN OUTAGE: no banner, no sentence, just the source view (which
    # says so itself when its own fetch 404s).
    test "a file gone between the stat and the read leaves the source view and no banner" do
      replacing(FileLayer.current, :read, ->(*) { raise FileLayer::NotFound, "gone" }) do
        get file_path(@readme.node_id)
      end
      assert_response :success

      assert_select ".markdown-view", 0
      assert_select ".markdown-note", 0
      assert_select ".library-unreachable", 0
      assert_select ".preview .preview-code", 1
    end
  end
end
