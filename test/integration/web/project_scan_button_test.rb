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
  end
end
