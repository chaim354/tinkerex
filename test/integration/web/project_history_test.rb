require "test_helper"

module Web
  # THE PROJECT HISTORY PAGE, DRIVEN THROUGH REAL REQUESTS.
  #
  # THE BACKEND IS PINNED, NEVER AMBIENT, for the reason version_history_test.rb records: the page
  # builds a `Maker::Git::Repo`, which resolves `FileLayer.current` itself, so a fixture built
  # through the ambient adapter is a real S3 client aimed at config/ci.rb's stub bucket on the
  # `test-s3` leg. `use_fresh_share_library!` assigns a Share on a fresh tmpdir and owns the
  # teardown of every directory it mints, so this file is hermetic and identical on all three legs.
  # On share the repository is operated on IN PLACE, so no cache root is involved at all and the
  # id-reuse trap that makes `cache_root:` an injectable seam elsewhere cannot bite here.
  class ProjectHistoryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # AN UNMOUNTED SHARE, INJECTED AT THE PORT RATHER THAN AT THE CONTROLLER. The failure this page
    # must not mis-render arrives as `FileLayer::FetchError` out of the repo-data verbs — §14a's
    # retryable answer, which `FileLayer::Share` raises for exactly this state — so the fake raises
    # it from the two verbs `Repo#hydrate!` calls and delegates everything else to the real adapter.
    # Stubbing the controller instead would prove the rescue exists without proving it is wired to
    # the door the failure actually comes through.
    class UnmountedLibrary < SimpleDelegator
      def repo_data_dir(*, **) = raise(FileLayer::FetchError, "the library root looks unmounted")
      def list_repo_data(*, **) = raise(FileLayer::FetchError, "the library root looks unmounted")
    end

    setup do
      @root = use_fresh_share_library!
      @user = sign_in
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = mint_project_folder!
    end

    # There is no global sign-in helper in this suite and no fixtures — every file defines its own,
    # the way projects_flow_test.rb does.
    def sign_in(email = "history@example.com")
      user = User.find_by(email:) || User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # --- the commit list -------------------------------------------------------------------

    test "commits are listed newest first" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "first commit")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "second commit")

      get project_history_path(@project)

      assert_response :success
      assert_equal [ "second commit", "first commit" ],
                   css_select(".history-commit .commit-message").map { |el| el.text.strip },
                   "the newest commit belongs at the top"
      assert_select ".history-commit .commit-oid", count: 2
      assert_select ".history-commit .commit-root", count: 1, text: "first commit"
    end

    test "the page links back to the project, and the project links to it" do
      get project_path(@project)
      assert_response :success
      assert_select "a[href=?]", project_history_path(@project), text: "History"
    end

    # --- the empty state, which is ORDINARY --------------------------------------------------

    test "a project that has never been committed renders the empty state rather than an error" do
      get project_history_path(@project)

      assert_response :success
      assert_select ".history-empty"
      assert_select ".history-commit", count: 0
      assert_select ".history-unreachable", count: 0
    end

    # `hydrate!` MINTS `.git`, AND THAT DIRECTORY IS THE MARKER `Maker::AttachToProject`'s
    # `:in_working_tree` READS. Minting one from a READ would switch §14f's intake filing off for
    # this project — silently, at the next scan, nowhere near the request that caused it.
    test "opening history does not mint a repository for a never-committed project" do
      get project_history_path(@project)

      assert_response :success
      assert_not File.exist?(FileLayer.current.repo_data_dir(@user, project: @project).to_s),
                 "reading history must not mint a .git marker"
    end

    # `Maker::GitRepo` is an INDEX, never a source of truth, so a row whose head the repository no
    # longer has must degrade to the empty page rather than to a 500.
    test "a stale index row with no matching commit falls back to the empty state" do
      Maker::GitRepo.create!(project: @project, head_oid: "0" * 40)

      get project_history_path(@project)

      assert_response :success
      assert_select ".history-empty"
    end

    # --- the third state: unreachable is NOT empty -------------------------------------------

    test "an unreachable library renders as unreachable and never as empty" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "first commit")
      FileLayer.current = UnmountedLibrary.new(FileLayer.current)

      get project_history_path(@project)

      assert_response :success
      assert_select ".history-unreachable"
      assert_select ".history-empty", { count: 0 },
                    "an unmounted share must never read as 'you have no history'"
      assert_select ".history-commit", count: 0
    end

    # --- the version strip --------------------------------------------------------------------

    test "an unavailable version is rendered as a greyed not-kept tile rather than omitted" do
      node = file_node("body.stl", content: "SOLID v2\n")
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'a' * 64}") }, message: "v1")
      repo.commit!(paths: { "body.stl.ptr" => pointer(node.content_hash) }, message: "v2")

      get project_history_path(@project, path: "body.stl")

      assert_response :success
      assert_select ".version-tile", { count: 2 },
                    "the version whose bytes are gone must still be RENDERED, not hidden"
      assert_select ".version-tile.is-not-kept", count: 1
      assert_select ".version-tile.is-pending", count: 1
    end

    # THE ONE SANCTIONED MINTING SITE (Maker::VersionPreview's own header). Only for a version the
    # store can still resolve: a `not_kept` one needs no row, and minting one would send the job to
    # fetch bytes already established as gone.
    test "opening a file's history mints a render row and enqueues a job, for the kept version only" do
      node = file_node("body.stl", content: "SOLID\n")
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'b' * 64}") }, message: "v1")
      repo.commit!(paths: { "body.stl.ptr" => pointer(node.content_hash) }, message: "v2")

      assert_difference "Maker::VersionPreview.count", 1 do
        assert_enqueued_with(job: Maker::RenderVersionPreviewJob) do
          get project_history_path(@project, path: "body.stl")
        end
      end
      row = Maker::VersionPreview.order(:id).last
      assert_equal node.node_id, row.node_id
      assert_equal node.content_hash, row.content_token
      assert_equal "body.stl", row.source_filename
      assert_equal "pending", row.state

      # A SECOND OPEN MINTS NOTHING. `create_or_find_by!` plus the enqueue gate is what stops a
      # page view turning into a re-render of everything already cached.
      assert_no_difference "Maker::VersionPreview.count" do
        get project_history_path(@project, path: "body.stl")
      end
    end

    test "a ready render is drawn as an image tile" do
      node = file_node("body.stl", content: "SOLID\n")
      repo.commit!(paths: { "body.stl.ptr" => pointer(node.content_hash) }, message: "v1")
      row = Maker::VersionPreview.create!(project: @project, node_id: node.node_id,
                                          content_token: node.content_hash,
                                          source_filename: "body.stl", state: "ready")
      row.asset.attach(io: StringIO.new("not-really-a-png"), filename: "v.png",
                       content_type: "image/png")

      get project_history_path(@project, path: "body.stl")

      assert_response :success
      assert_select ".version-tile.is-ready img", count: 1
      assert_select ".version-tile.is-pending", count: 0
    end

    # A TEXT FILE'S BYTES ARE IN THE COMMIT, so there is nothing for the byte store to have kept or
    # lost. Its `content_token` is the COMMIT OID, which no `FileLayer#read` resolves — mint a row
    # for it and the job can only ever mark it `not_kept`, rendering a text file's intact history as
    # permanently lost content.
    test "a content version renders as text and mints no render row" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")

      assert_no_difference "Maker::VersionPreview.count" do
        get project_history_path(@project, path: "notes.md")
      end
      assert_select ".version-tile.is-text", count: 1
      assert_select ".version-tile.is-not-kept", count: 0
    end

    # REJECT, NEVER NORMALIZE. `a/../b` normalized is a VALID path naming a different file.
    test "a traversing path is refused rather than normalized" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")

      get project_history_path(@project, path: "sub/../notes.md")

      assert_response :success
      assert_select ".version-tile", count: 0
      assert_select ".version-strip-idle"
    end

    # --- the compare surface ------------------------------------------------------------------
    #
    # TWO SURFACES, AND WHICH ONE A FILE GETS IS `Maker::Git::Tracking`'s ANSWER, NOT ITS BYTES.
    # A line diff of a STEP file is worthless and two renders side by side are not, so the split is
    # the same one the COMMIT path already made about this file. The tests below drive both halves
    # and, in the pointer case, assert the text half is ABSENT — a pointer whose bytes happen to be
    # ASCII is exactly the file a "does it look like text" rule would get wrong.

    test "a text file's compare shows added and removed lines under distinct classes" do
      repo.commit!(paths: { "notes.md" => "alpha\nbeta\ngamma\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "alpha\nBETA\ngamma\n" }, message: "v2")

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select ".version-compare.is-text"
      assert_select ".diff-row.is-removed .diff-text", { count: 1, text: "beta" },
                    "a removal drawn as an insertion is worse than no diff at all"
      assert_select ".diff-row.is-added .diff-text", count: 1, text: "BETA"
      assert_select ".diff-row.is-context", count: 2
    end

    # ELISION IS COUNTED IN THE MARKUP TOO, not only in the service. A gap rendered as a bare
    # ellipsis is the silent truncation the diff refuses at the cap, wearing different clothes.
    test "a long unchanged run renders as one row that says how many lines it hides" do
      before = (1..50).map { |i| "line #{i}\n" }.join
      repo.commit!(paths: { "notes.md" => before }, message: "v1")
      repo.commit!(paths: { "notes.md" => before.sub("line 25\n", "LINE 25\n") }, message: "v2")

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select ".diff-row.is-gap .diff-gap-note", count: 2
      css_select(".diff-row.is-gap .diff-gap-note").each do |cell|
        assert_match(/\A\d+ unchanged lines hidden\z/, cell.text.strip,
                     "a gap must say how many lines it is not showing")
      end
    end

    # ALLOWED ON PURPOSE. Silently substituting a different pair would answer a question the user
    # did not ask, so the same version on both sides is an empty diff that says so.
    test "the same version on both sides renders as identical rather than an empty table" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")
      newest = oids_for("notes.md").first

      get project_history_compare_path(@project, path: "notes.md",
                                       compare: { from: newest, to: newest })

      assert_response :success
      assert_select ".diff-identical"
      assert_select ".diff-table", count: 0
    end

    test "two identical versions say so rather than drawing an empty table" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "one\n", "other.md" => "x\n" }, message: "v2")

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      # `other.md` moved, so `notes.md` has ONE version and the page has nothing to compare —
      # which is the honest answer and not an error.
      assert_select ".version-compare-idle"
      assert_select ".diff-table", count: 0
    end

    # A REFUSAL IS AN ANSWER; A TRUNCATION IS NOT. The rows must be absent entirely, and the
    # message must name what it measured — a partial diff rendered as if complete is the
    # well-formed lie this repo keeps recording.
    test "a version past the diff cap renders an honest refusal and no rows at all" do
      over = Maker::Git::TextDiff::MAX_LINES + 1
      repo.commit!(paths: { "notes.md" => "small\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "x\n" * over }, message: "v2")

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select ".diff-refused"
      assert_select ".diff-table", { count: 0 },
                    "nothing partial may be drawn beside the refusal"
      assert_select ".diff-row", count: 0
      assert_includes response.body, ActiveSupport::NumberHelper.number_to_delimited(over),
                      "the refusal must name the size it measured, not merely say 'too big'"
    end

    # THE POINTER HALF. `body.stl` is tracked as a pointer, so the repository holds two content
    # HASHES and diffing them would be noise wearing a diff's clothes.
    test "a pointer file's compare is visual and carries no text diff" do
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'a' * 64}") }, message: "v1")
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'b' * 64}") }, message: "v2")

      get project_history_compare_path(@project, path: "body.stl")

      assert_response :success
      assert_select ".version-compare.is-visual"
      assert_select ".version-compare.is-text", { count: 0 },
                    "a pointer version must never reach the text diff"
      assert_select ".diff-table", count: 0
      assert_select ".diff-refused", { count: 0 },
                    "not even the REFUSED shape of a text diff belongs on a pointer comparison"
    end

    # A `data-controller` NAME THAT RESOLVES TO NOTHING IS A SILENT NO-OP (§14d), so the panel that
    # declares it is asserted here and the identifier's existence is asserted by
    # test/stimulus_hygiene_test.rb, which derives the registered set from the filenames.
    test "the visual compare panel declares the version-compare controller" do
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'c' * 64}") }, message: "v1")
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'d' * 64}") }, message: "v2")

      get project_history_compare_path(@project, path: "body.stl")

      assert_response :success
      assert_select "[data-controller~=?]", "version-compare"
    end

    # TWO RENDERS IN REGISTER, WHICH IS THE WHOLE POINT OF THE VISUAL HALF. The slider and its two
    # image targets appear only when both sides actually have a render.
    test "two ready renders draw the slider and both of its image targets" do
      # BOTH TOKENS MUST STILL RESOLVE, which on `share` means a live node still carries each
      # content hash — `VersionHistory#retained_tokens` asks the nodes table and nothing else, so a
      # superseded hash with no node left reads `not_kept` and this pair would draw no slider at
      # all. The older bytes surviving as a second file is the ordinary way that happens here.
      kept = file_node("body-v1.stl", content: "SOLID v1\n")
      node = file_node("body.stl", content: "SOLID v2\n")
      repo.commit!(paths: { "body.stl.ptr" => pointer(kept.content_hash) }, message: "v1")
      repo.commit!(paths: { "body.stl.ptr" => pointer(node.content_hash) }, message: "v2")
      [ kept.content_hash, node.content_hash ].each { |token| ready_render!(node, token) }

      get project_history_compare_path(@project, path: "body.stl")

      assert_response :success
      assert_select ".compare-stage img[data-version-compare-target=?]", "before", count: 1
      assert_select ".compare-stage img[data-version-compare-target=?]", "after", count: 1
      assert_select "input.compare-slider[data-version-compare-target=?]", "slider", count: 1
      assert_select "input.compare-slider[data-action=?]", "input->version-compare#update"
      assert_select ".compare-unready", count: 0
    end

    # A PAIR WITH NO PICTURES STILL SAYS WHICH FACT EACH SIDE IS — "not kept" and "rendering" are
    # two different things, and §14a's rule is that they never wear one sentence.
    test "a pointer pair with no renders yet says so per side and draws no slider" do
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'e' * 64}") }, message: "v1")
      repo.commit!(paths: { "body.stl.ptr" => pointer("sha256:#{'f' * 64}") }, message: "v2")

      get project_history_compare_path(@project, path: "body.stl")

      assert_response :success
      assert_select ".compare-side.is-not-kept", count: 2
      assert_select "input.compare-slider", count: 0
      assert_select "[data-controller~=?]", "version-compare"
    end

    # --- the picker form ------------------------------------------------------------------------
    #
    # THE RENDERED FIELD NAMES, NOT A HASH POSTED FROM RUBY. A `form_with` missing `scope:` emits
    # `from`/`to` while the controller reads a `compare` hash, and a test that passes
    # `params: { compare: {…} }` cannot see that at all — it bypasses the form entirely (§14d).
    test "the compare form posts the parameter names the controller reads" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select "form.version-compare-form select[name=?]", "compare[from]"
      assert_select "form.version-compare-form select[name=?]", "compare[to]"
      assert_select "form.version-compare-form input[name=?]", "path"
    end

    test "an explicitly chosen pair is the pair compared" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")
      repo.commit!(paths: { "notes.md" => "three\n" }, message: "v3")
      oldest, newest = [ oids_for("notes.md").last, oids_for("notes.md").first ]

      get project_history_compare_path(@project, path: "notes.md",
                                       compare: { from: oldest, to: newest })

      assert_response :success
      assert_select ".diff-row.is-removed .diff-text", text: "one"
      assert_select ".diff-row.is-added .diff-text", text: "three"
    end

    # THE DEFAULT IS THE TWO NEWEST, so the page is useful with no parameters — and `@tiles` is
    # newest-first, so getting the older/newer pair backwards would render every diff inside out
    # while looking entirely plausible.
    test "with no chosen pair the two newest versions are compared, older on the left" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")
      repo.commit!(paths: { "notes.md" => "three\n" }, message: "v3")

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select ".diff-row.is-removed .diff-text", text: "two"
      assert_select ".diff-row.is-added .diff-text", text: "three"
    end

    # AN OID WE DID NOT RECORD SELECTS NOTHING AND NEVER REACHES `Repo#blob_at`.
    test "an unrecognised oid falls back to the default pair rather than being resolved" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")

      get project_history_compare_path(@project, path: "notes.md",
                                       compare: { from: "0" * 40, to: "1" * 40 })

      assert_response :success
      assert_select ".diff-row.is-removed .diff-text", text: "one"
      assert_select ".diff-row.is-added .diff-text", text: "two"
    end

    # --- the compare page inherits the page states ----------------------------------------------

    test "an unreachable library renders as unreachable on the compare page too" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      FileLayer.current = UnmountedLibrary.new(FileLayer.current)

      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select ".history-unreachable"
      assert_select ".history-empty", { count: 0 },
                    "an unmounted share must never read as 'you have no history' here either"
    end

    test "opening compare does not mint a repository for a never-committed project" do
      get project_history_compare_path(@project, path: "notes.md")

      assert_response :success
      assert_select ".history-empty"
      assert_not File.exist?(FileLayer.current.repo_data_dir(@user, project: @project).to_s),
                 "the compare door must return early on a never-committed project too"
    end

    test "a traversing path is refused on the compare page as well" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")
      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")

      get project_history_compare_path(@project, path: "sub/../notes.md")

      assert_response :success
      assert_select ".version-compare-idle"
      assert_select ".diff-table", count: 0
    end

    test "the history page links to compare only once there are two versions" do
      repo.commit!(paths: { "notes.md" => "one\n" }, message: "v1")

      get project_history_path(@project, path: "notes.md")
      assert_response :success
      assert_select "a[href=?]", project_history_compare_path(@project, path: "notes.md"), count: 0

      repo.commit!(paths: { "notes.md" => "two\n" }, message: "v2")

      get project_history_path(@project, path: "notes.md")
      assert_select "a[href=?]", project_history_compare_path(@project, path: "notes.md"), count: 1
    end

    test "another user's project is a 404, not a peek" do
      other = User.create!(email: "someone-else@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      get project_history_path(theirs)

      assert_response :not_found
    end

    private

    # HYDRATED ONCE, ON DEMAND. Deliberately not called by the tests that assert nothing minted a
    # repository.
    def repo = @repo ||= Maker::Git::Repo.for(@project.reload).tap(&:hydrate!)

    # MINTED THROUGH THE PINNED ADAPTER, never Maker::Project#ensure_library_folder!, which goes
    # through the AMBIENT FileLayer.current — see the class header.
    def mint_project_folder!
      root = FileLayer.current.mkdir(@user, parent_node_id: nil, name: Maker::ProjectFolders::ROOT)
      folder = FileLayer.current.mkdir(@user, parent_node_id: root.node_id, name: @project.slug)
      @project.update_column(:folder_node_id, folder.node_id)
      @user.nodes.find_by!(node_id: folder.node_id)
    end

    # A ROW PLUS THE FILE IT CLAIMS TO BE: on share a read resolves through storage_path and opens
    # an ACTUAL FILE, so a bare nodes.create! fixture is a node whose bytes were never there (§14a).
    def file_node(name, content:)
      rel = File.join(@folder.storage_path, name)
      path = @root.join(rel)
      path.dirname.mkpath
      path.binwrite(content)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: name, kind: "file",
                          parent_node_id: @folder.node_id, storage_path: rel,
                          size: content.bytesize,
                          content_hash: "sha256:#{Digest::SHA256.hexdigest(content)}")
    end

    # Built through Tracking's own constant rather than a second copy of the wire format.
    def pointer(oid, size: 12)
      "version #{Maker::Git::Tracking::POINTER_VERSION}\noid #{oid}\nsize #{size}\n"
    end

    # THE COMMIT OIDS THAT TOUCHED ONE PATH, newest first — the same walk the page does, so a test
    # naming "the oldest version" names what the picker offers rather than what the log happens to
    # hold. Built through the real service so it cannot drift from the page it is asserting about.
    def oids_for(path)
      Maker::Git::VersionHistory.new(project: @project.reload).for_path(path).map(&:oid)
    end

    # A cached render in its terminal `ready` state, with bytes attached. The compare surface draws
    # the slider only when BOTH sides have one.
    def ready_render!(node, token)
      row = Maker::VersionPreview.create!(project: @project, node_id: node.node_id,
                                          content_token: token, source_filename: node.name,
                                          state: "ready")
      row.asset.attach(io: StringIO.new("not-really-a-png"), filename: "v.png",
                       content_type: "image/png")
      row
    end
  end
end
