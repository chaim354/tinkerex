require "test_helper"

module Web
  # The on-demand "Rescan" button. A share/s3 library only refreshes on the 15-minute recurring
  # Library::ScanJob; a user who just edited files on the NAS wants the index caught up NOW. This
  # ENQUEUES a scan for the current user (never runs it inline -- a large NAS would block the
  # request) and redirects.
  #
  # GATED ON `scannable`, ON BOTH SURFACES. The button is hidden in chunk mode (its catalog is the
  # sync engine's changelog, so a manual scan is meaningless), AND the action refuses a POST there.
  # The hidden button is UX; the action gate is the guarantee -- a hand-crafted POST must not
  # enqueue a job that would only fail (ScanJob#perform raises ArgumentError for a chunk backend).
  #
  # `FileLayer.current =` for the scannable leg rather than pin_file_layer_backend, following
  # share_delivery_test.rb: a Share adapter needs a tmpdir ROOT that pin (which rebuilds from ENV)
  # does not supply. The teardown reset is load-bearing, not decoration -- a direct assignment
  # does not set @file_layer_backend_pinned, so test_helper's teardown will not clean up after it.
  class RescanTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "rescan-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # A scannable deployment. Share is the simplest to stand up (a tmpdir root); the gate is the
    # capability, not the class, so s3 would behave identically here.
    def use_scannable_backend
      @root = Pathname.new(Dir.mktmpdir("rescan"))
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    end

    # --- Scannable (share/s3): the button is offered and the POST enqueues a scan ---

    test "a scannable library shows the Rescan button" do
      use_scannable_backend
      get files_path
      assert_response :success
      # assert_select on the form action, NOT a text match: the signed-in user's email starts
      # "rescan-...@example.com", so /rescan/i on the body matches trivially and pins nothing.
      assert_select "form[action=?] button", rescan_files_path, text: /rescan/i
    end

    # The one that matters: the POST enqueues -- it does NOT run the scan inline -- and it names
    # exactly the current user, the same shape the recurring s3 fan-out uses
    # (scan_job_test.rb: args: [{ user_id: user.id }]). assert_enqueued_with proves it went to the
    # queue, not that a scan happened, which is the whole point of enqueuing.
    test "POST /files/rescan enqueues a Library::ScanJob for the current user, then redirects" do
      use_scannable_backend
      assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id } ]) do
        post rescan_files_path
      end
      assert_redirected_to files_path
      assert_match(/rescan started/i, flash[:notice])
    end

    # Preserving the folder is a nice-to-have, pinned so it does not silently regress: a user who
    # rescans from inside a folder lands back in that folder.
    test "the rescan redirect preserves the current folder" do
      use_scannable_backend
      @user.nodes.create!(node_id: "dir-1", name: "cad", kind: "dir")
      post rescan_files_path(folder: "dir-1")
      assert_redirected_to files_path(folder: "dir-1")
    end

    # --- Chunk mode: the button is absent AND the POST is gated (does not enqueue) ---

    test "chunk mode does not show the Rescan button" do
      pin_file_layer_backend("chunk")
      get files_path
      assert_response :success
      # count: 0, not a body text match -- the user's email contains "rescan".
      assert_select "form[action=?]", rescan_files_path, count: 0
    end

    # THE MUTATION TARGET. Remove require_scannable! from the controller and this goes RED: the
    # action would call perform_later regardless of backend, enqueuing a job whose #perform then
    # raises ArgumentError ("not a scanned backend"). The hidden button is not enough -- a POST
    # can arrive without rendering the page -- so the action itself must refuse. The redirect +
    # alert is the web idiom (FilesController's rescue_from handlers all redirect with a flash);
    # a JSON 501 from require_capability! would show a human raw JSON.
    test "chunk mode: POST /files/rescan does not enqueue a scan, and redirects with an alert" do
      pin_file_layer_backend("chunk")
      assert_no_enqueued_jobs do
        post rescan_files_path
      end
      assert_redirected_to files_path
      assert_match(/doesn't support|not.*support/i, flash[:alert])
    end
  end
end
