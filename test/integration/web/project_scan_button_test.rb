require "test_helper"

module Web
  # The per-project "Scan folder" button: refresh the library from storage NOW, instead of waiting
  # for library_scan's 15 minutes (share/s3) or remote_changelog_pull's 2 (chunk_remote).
  #
  # EVERY TEST FORCES ITS BACKEND rather than reading the ambient LIBRARY_BACKEND, so all of them
  # run on all three CI legs. §15 requires the three legs to report IDENTICAL run counts; a test
  # that skipped on two of them would make this file the reason they diverge.
  class ProjectScanButtonTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::Base.cache_store.clear
      @user = User.create!(email: "scan-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    teardown { FileLayer.reset! }

    def use_share!
      @root = Pathname.new(Dir.mktmpdir("scan-btn"))
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    end

    # `client:` from FakeS3, matching every other S3 construction in this suite
    # (s3_write_test.rb, s3_delivery_test.rb, repo_history_flow_test.rb). Without it the adapter
    # builds a REAL Aws::S3::Client at construction — nothing here would call it, but the house
    # pattern exists so no test can ever accidentally reach the network.
    def use_s3!
      require_relative "../../support/fake_s3"
      @fake_s3 = FakeS3.new
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", client: @fake_s3.client)
    end

    # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` DOES NOT EXIST in
    # this suite and `require "minitest/mock"` is a LoadError. test_helper.rb's
    # #without_svg_rasterizer and #with_concurrent_file_attachment rebind singleton methods exactly
    # this way, and so does project_folder_intake_test.rb.
    #
    # `original` is an UnboundMethod and `define_method` takes one directly, so the ensure
    # reinstalls the EXACT original implementation rather than hoping something else is underneath
    # it. The `own` branch is why this is a helper and not four copies: a method INHERITED from an
    # ancestor (ActiveJob::Base's `perform_now`) must be REMOVED to restore inheritance —
    # redefining it would leave a permanent shadow on this subclass's singleton class, which no
    # later test would notice and none should have to.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    test "on share the button enqueues a library scan and says one is running" do
      use_share!
      assert_enqueued_with(job: Library::ScanJob,
                           args: [ { user_id: @user.id, root: @root.to_s } ]) do
        post project_scan_path(@project)
      end
      assert_redirected_to project_path(@project, scanning: 1)
      assert_match(/scanning your library/i, flash[:notice].to_s)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "on s3 the enqueued scan carries NO root — no bucket credentials into the queue" do
      use_s3!
      assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id } ]) do
        post project_scan_path(@project)
      end
      assert_redirected_to project_path(@project, scanning: 1)
    end

    # THE §14f RACE. Library::ScanJob files inline, strictly after observer.call. A second filer
    # started from here would move a file after the Scanner captured its observations; the
    # Reconciler pairs it back by (content_hash, size) and repoints the node to its OLD path while
    # the bytes sit at the new one — and in that window library_present? still reads true, so
    # Share#download's ENOENT maps to NotFound and the user gets a TERMINAL 404 for a file that is
    # not gone. The button must enqueue and stop.
    test "a scannable backend does NOT file synchronously — that would race the Scanner" do
      use_share!
      called = false
      replacing(Maker::ProjectIntake, :for_project, ->(**) { called = true }) do
        post project_scan_path(@project)
      end
      assert_not called, "the scan door must not run the intake on a scannable backend"
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "another user's project is not scannable through this door" do
      use_share!
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Not Mine")
      assert_no_enqueued_jobs(only: Library::ScanJob) do
        post project_scan_path(theirs)
      end
      assert_response :not_found
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # ORDER IS THE ASSERTION, not merely that both ran: filing before the pull would report on a
    # stale mirror, which is the whole failure this button exists to end.
    test "on chunk_remote the pull runs first and the intake second" do
      FileLayer.current = FileLayer::ChunkRemote.new
      order = []
      pull = ->(**) { order << :pull }
      file = lambda do |**|
        order << :file
        # `plan` CARRIES THE MOVE THIS STUB CLAIMS (stage 4, S4-2): the notice reads what was FILED
        # off Result#plan now, not off `moved`, so a stub asserting "filed 1" has to carry the pair
        # #place would have built.
        Maker::ProjectIntake::Result.new(attached: 2, moved: 1, skipped: 0,
                                         skips: [], plan: [ [ "panel.svg", "design" ] ], status: :ok)
      end
      replacing(FileLayer::RemoteChangelogPullJob, :perform_now, pull) do
        replacing(Maker::ProjectIntake, :for_project, file) do
          post project_scan_path(@project)
        end
      end
      assert_equal %i[pull file], order
      assert_redirected_to project_path(@project)
      assert_match(/attached 2/i, flash[:notice].to_s)
      assert_match(/filed 1/i, flash[:notice].to_s)
    end

    test "on chunk_remote a project with no folder is told so, and no folder is created" do
      FileLayer.current = FileLayer::ChunkRemote.new
      none = Maker::ProjectIntake::Result.new(attached: 0, moved: 0, skipped: 0, skips: [],
                                              plan: [], status: :no_folder)
      replacing(FileLayer::RemoteChangelogPullJob, :perform_now, ->(**) { }) do
        replacing(Maker::ProjectIntake, :for_project, ->(**) { none }) do
          post project_scan_path(@project)
        end
      end
      assert_match(/no folder yet/i, flash[:notice].to_s)
      assert_nil @project.reload.folder_node_id,
                 "the scan door must never call ensure_library_folder! — a folder minted as a " \
                 "side effect of merely looking is the bug #relocate shipped"
    end

    # The conflict clause has ONE home (ProjectFolderIntake#project_intake_sentence). This door is
    # its fourth caller and must not paraphrase it.
    test "a collision left at the project root is named in the same words every other door uses" do
      FileLayer.current = FileLayer::ChunkRemote.new
      clash = Maker::ProjectIntake::Result.new(attached: 1, moved: 0, skipped: 1,
                                               skips: [ [ "panel.stl", :conflict ] ],
                                               plan: [], status: :ok)
      replacing(FileLayer::RemoteChangelogPullJob, :perform_now, ->(**) { }) do
        replacing(Maker::ProjectIntake, :for_project, ->(**) { clash }) do
          post project_scan_path(@project)
        end
      end
      assert_match(/already in #{Maker::ProjectFolders.folder_for(@user, 'panel.stl')}\//,
                   flash[:notice].to_s)
      assert_match(/stayed at the project root/i, flash[:notice].to_s)
    end

    # NOT ONLY ABUSE CONTROL. Library::ScanJob's `on_conflict: :discard` silently DROPS a second
    # enqueue while one is running, so without this the user gets "Scanning…" and nothing happens.
    # The throttle is what turns that silence into a sentence.
    test "a fourth scan in a minute is refused with a message rather than silently discarded" do
      use_share!
      3.times do
        post project_scan_path(@project)
        assert_redirected_to project_path(@project, scanning: 1), "under the limit"
      end
      post project_scan_path(@project)
      assert_redirected_to project_path(@project)
      assert_match(/give it a moment/i, flash[:alert].to_s)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # THE KEY IS THE USER, NOT THE ADDRESS. `by:` overrides rate_limit's default
    # `request.remote_ip`, which is 127.0.0.1 for EVERY integration test (§14e) and, on a
    # self-hosted box behind one NAT address, for every member of a household. Left at the
    # default, one person exhausting the budget would refuse everyone else's scan — and no
    # assertion above would notice, because each test signs in as one user.
    test "one user exhausting the budget does not refuse another user's scan" do
      use_share!
      4.times { post project_scan_path(@project) }
      assert_match(/give it a moment/i, flash[:alert].to_s, "the first user is now throttled")

      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Their Lamp")
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other.email, password: PASSWORD } }

      assert_enqueued_jobs 1, only: Library::ScanJob do
        post project_scan_path(theirs)
      end
      assert_redirected_to project_path(theirs, scanning: 1)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # Guards the counter itself. With a NullStore, increment returns nil and ActionController's
    # `count && count > to` makes every throttle here a no-op that no other assertion would notice.
    test "the store backing this throttle is real, not a null store" do
      assert_not_kind_of ActiveSupport::Cache::NullStore, ActionController::Base.cache_store
    end

    # ASSERT THE RENDERED MARKUP, not a Ruby hash. §14d records two shipped bugs invisible to a
    # green suite because the tests POSTed `params: { x: {...} }` and bypassed the form entirely.
    test "the project page renders a scan button pointing at this project's scan path" do
      use_share!
      get project_path(@project)
      assert_response :success
      assert_select "form[action=?]", project_scan_path(@project) do
        assert_select "button", text: /scan folder/i
      end
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "the reload element appears only after a scan started, never on a plain view" do
      use_share!
      get project_path(@project)
      assert_select "[data-controller~=?]", "scanreload", false,
                    "a plain project view must not schedule a reload"

      get project_path(@project, scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", 1
      # The reload target is the param-FREE url. That is what stops it looping: the reloaded page
      # carries no ?scanning=1, renders no scanreload element, and schedules nothing.
      assert_select "[data-scanreload-url-value=?]", project_path(@project)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # chunk_remote finishes its work inside the request, so there is nothing to wait for.
    test "chunk_remote never renders the reload element" do
      FileLayer.current = FileLayer::ChunkRemote.new
      get project_path(@project, scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", false
    end
  end
end
