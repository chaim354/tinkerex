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
  end
end
