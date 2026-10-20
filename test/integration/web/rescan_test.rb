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
  # does not supply. The teardown below is load-bearing for `use_scannable_backend`, which
  # hand-rolls its own tmpdir -- a direct assignment sets no @file_layer_backend_pinned, so nothing
  # else removes that one. It is NOT what cleans up setup's root, and could not be:
  # `use_scannable_backend` REASSIGNS `@root`, so this teardown saw only the second directory and
  # leaked the first on every test that calls it. That is why `use_fresh_share_library!` records
  # the directories it mints itself rather than trusting `@root` (test_helper.rb).
  class RescanTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A real share library, and fixtures that exist on disk -- see test_helper's create_node!
      # for why (§14a: a bare nodes.create! leaves a NULL storage_path, which cannot exist here).
      @root = use_fresh_share_library!
      @user = User.create!(email: "rescan-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
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

    # The one that matters: the POST enqueues -- it does NOT run the scan inline. Exactly one job,
    # which is what proves the response came from a queue write rather than from a scan having
    # happened. WHAT the job carries is the next test's subject, deliberately split out: these are
    # two different claims about the same call and only one of them is about this action.
    test "POST /files/rescan enqueues a Library::ScanJob for the current user, then redirects" do
      use_scannable_backend
      assert_enqueued_jobs 1, only: Library::ScanJob do
        post rescan_files_path
      end
      assert_redirected_to files_path(scanning: 1)
      assert_match(/scanning your library/i, flash[:notice])
    end

    # THE ROOT REACHES THE QUEUE, AND THAT IS OPERATOR VISIBILITY, NOT DECORATION. ActiveJob
    # serializes these arguments into the queue's database, where they outlive the run: a share
    # scan that REFUSES (Library::Scanner::UnsafeScan -- an unmounted NAS, a typo'd LIBRARY_PATH)
    # leaves one failed-jobs row, and `root:` is the only thing in it that says WHICH root refused.
    # ScanJob deliberately has no retry_on for that refusal precisely because the row IS the report.
    #
    # THE REGRESSION GUARD FOR THIS DOOR GOING THROUGH .enqueue_for. It used to call
    # `perform_later(user_id:)` itself -- a third enqueuer beside .enqueue_for and .scan_all!,
    # naming no root -- so a rescan started from this button was anonymous in that table on the one
    # deployment where the root is the useful half. The other half of .enqueue_for's rule (an s3
    # library enqueues with NO root, because its target is a bucket plus the credentials to reach
    # it) is pinned where that decision lives, in scan_job_test.rb's ScanJobEnqueueForTest.
    test "on a share library the enqueued scan carries the root, so a failure names it" do
      use_scannable_backend
      assert_enqueued_with(job: Library::ScanJob,
                           args: [ { user_id: @user.id, root: @root.to_s } ]) do
        post rescan_files_path
      end
    end

    # Preserving the folder is a nice-to-have, pinned so it does not silently regress: a user who
    # rescans from inside a folder lands back in that folder.
    test "the rescan redirect preserves the current folder" do
      use_scannable_backend
      create_node!(@user, node_id: "dir-1", name: "cad", kind: "dir")
      post rescan_files_path(folder: "dir-1")
      assert_redirected_to files_path(folder: "dir-1", scanning: 1)
    end

    # The type filter is the other thing a user can be "inside", and the same argument applies:
    # rescanning from a filtered view and landing at the unfiltered root is a lost place. The
    # button carries files_query_base, so the value arrives here; the redirect puts it back
    # through resolve_exts rather than echoing it, which is why the junk case below is a plain
    # root redirect and not a reflected parameter.
    test "the rescan redirect preserves the type filter, and revalidates it" do
      use_scannable_backend
      post rescan_files_path(ext: "stl,3mf")
      assert_redirected_to files_path(ext: "stl,3mf", scanning: 1)

      post rescan_files_path(ext: "../etc")
      assert_redirected_to files_path(scanning: 1)
    end

    test "the rescan button carries the filter it was clicked from" do
      use_scannable_backend
      create_node!(@user, node_id: "n-1", name: "a.stl", kind: "file", mtime: 1, size: 1)
      get files_path(ext: "stl")
      assert_select "form[action=?]", rescan_files_path(ext: "stl")
    end

    # --- A NON-SCANNABLE BACKEND: the button is absent AND the POST is gated ---
    #
    # `chunk_remote`, selected EXPLICITLY, where these used to rely on the ambient backend being
    # embedded chunk. The property is unchanged and is not about chunk specifically: `scannable`
    # asks whether this backend's catalog comes from POLLING the store (§14b), and a chunk-family
    # backend's tree is the changelog, so there is nothing to rescan. Constructing the adapter
    # needs no sync server -- `capabilities` is a constant and the gate runs before any port call.
    def use_non_scannable_backend = FileLayer.current = FileLayer::ChunkRemote.new

    test "a non-scannable backend does not show the Rescan button" do
      use_non_scannable_backend
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
    test "a non-scannable backend: POST /files/rescan does not enqueue a scan, and alerts" do
      use_non_scannable_backend
      assert_no_enqueued_jobs do
        post rescan_files_path
      end
      assert_redirected_to files_path
      assert_match(/doesn't support|not.*support/i, flash[:alert])
    end

    # --- The status endpoint the Rescan reload polls ---

    # THE WHOLE CONTRACT: one key, an ISO string or null, and the CLIENT decides whether it moved.
    # `running:` is deliberately NOT in this payload — see the action's own comment for the two
    # sources that were rejected and why each would lie.
    test "scan_status reports null before any scan and the stamp after one" do
      use_scannable_backend
      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_response :success
      assert_nil JSON.parse(response.body).fetch("scanned_at")

      at = Time.utc(2026, 9, 7, 12, 0, 0)
      @user.update_column(:library_scanned_at, at)

      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_equal @user.reload.library_scanned_stamp, JSON.parse(response.body)["scanned_at"]
      assert_match(/^2026-09-07T12:00:00\.000000/, JSON.parse(response.body)["scanned_at"],
                   "microseconds, so two scans in one second are two answers")
    end

    # UNGATED ON `scannable`, ON PURPOSE. require_scannable! redirects with a flash — the right
    # refusal for a button, and a 302 to an HTML page is nonsense to a JSON poller. chunk_remote
    # never renders the element that polls this, and `null` is the true answer there anyway.
    test "scan_status answers on a non-scannable backend too, rather than redirecting" do
      FileLayer.current = FileLayer::ChunkRemote.new
      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_response :success
      assert_nil JSON.parse(response.body).fetch("scanned_at")
    end

    # ONE USER'S SCAN IS ONE USER'S. The column is on `users` and the action reads current_user;
    # this is the guard that keeps it that way if the action is ever "optimised" into a global.
    test "scan_status reports only the signed-in user's scan" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      other.update_column(:library_scanned_at, Time.current)

      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_nil JSON.parse(response.body).fetch("scanned_at")
    end

    # --- The Files page's own Rescan reload element ---

    # THE FILES PAGE GETS THE RELOAD ELEMENT THE PROJECT PAGE HAS HAD (stage 4, S4-3). Before this
    # its Rescan said "refresh in a moment" and left the refreshing to the user.
    test "the files page schedules a poll only after a scan started, and points at the param-free url" do
      use_scannable_backend
      get files_path
      assert_select "[data-controller~=?]", "scanreload", false

      get files_path(scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", 1
      assert_select "[data-scanreload-url-value=?]", files_path
      assert_select "[data-scanreload-status-url-value=?]", scan_status_files_path
      # NEVER SCANNED: an empty `since`, which the controller reads as "any stamp is news".
      assert_select "[data-scanreload-since-value=?]", ""
    end

    test "the poll element carries the stamp the page was rendered with, and keeps the folder" do
      use_scannable_backend
      create_node!(@user, node_id: "dir-1", name: "cad", kind: "dir")
      @user.update_column(:library_scanned_at, Time.utc(2026, 9, 7, 12, 0, 0))

      get files_path(folder: "dir-1", scanning: 1)

      assert_select "[data-scanreload-since-value=?]", @user.reload.library_scanned_stamp
      assert_select "[data-scanreload-url-value=?]", files_path(folder: "dir-1")
    end

    test "a non-scannable backend schedules no poll even with the marker" do
      FileLayer.current = FileLayer::ChunkRemote.new
      get files_path(scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", false
    end
  end
end
