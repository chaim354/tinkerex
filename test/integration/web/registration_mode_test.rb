require "test_helper"

module Web
  # Registration closed (the production default): the FIRST account is the owner — created
  # confirmed, signed in, no mail — and the page closes behind it. Drives the real requests and
  # follows the redirects, because that is where the earlier sign-up defect lived (§14e).
  class RegistrationModeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ENV["REGISTRATION"] = "closed"
      User.delete_all
    end

    teardown { ENV.delete("REGISTRATION") }

    def sign_up(email)
      post user_registration_path, params: { user: { email:, password: PASSWORD, password_confirmation: PASSWORD } }
    end

    test "on an empty server the sign-up page says the first account becomes the owner" do
      get new_user_registration_path
      assert_response :success
      assert_select "form[action=?]", user_registration_path
      assert_match(/first account/i, response.body)
      assert_match(/owner/i, response.body)
    end

    test "the first account is confirmed without mail, signed in, and closes sign-up behind it" do
      assert_emails 0 do
        sign_up("owner@example.com")
      end
      owner = User.find_by!(email: "owner@example.com")
      assert owner.confirmed?, "the owner needs no confirmation mail"
      follow_redirect!
      assert_response :success, "signed in and landed on a real page, not bounced to the sign-in page"

      delete destroy_user_session_path
      get new_user_registration_path
      assert_response :forbidden
      assert_match(/closed/i, response.body)
      get new_user_session_path
      assert_select "a[href=?]", new_user_registration_path, count: 0, text: "Sign up"
    end

    # THE FIRST ACCOUNT TRIGGERS THE FIRST SCAN (J, 2026-10-15), and only the first: scans are
    # enqueued per user, so a boot-time scan found no one to scan for on a fresh install and the
    # folder sat unindexed until Rescan. Enqueued, never performed here: on the s3 leg a performed
    # scan would list a bucket with stub credentials. On a CONFIRMED library (the fixture row): the
    # fresh-install case is the next test.
    test "the first account's sign-up enqueues the first library scan; a later account's does not" do
      if FileLayer.current.capabilities.scannable?
        assert_enqueued_with(job: Library::ScanJob) { sign_up("owner@example.com") }
        assert_equal User.find_by!(email: "owner@example.com").id,
                     enqueued_jobs.map { |j| j[:args].first }.find { |a| a.is_a?(Hash) && a.key?("user_id") }["user_id"]
      else
        assert_no_enqueued_jobs(only: Library::ScanJob) { sign_up("owner@example.com") }
      end
      delete destroy_user_session_path
      ENV["REGISTRATION"] = "open"
      assert_no_enqueued_jobs(only: Library::ScanJob) { sign_up("second@example.com") }
      assert User.exists?(email: "second@example.com"), "the second account was created (open sign-ups), with no scan"
    end

    # A FRESH SHARE INSTALL'S FIRST SIGN-UP SCANS NOTHING (K §3): nobody has said which folder is the
    # library yet, and the confirmation on /settings/library makes the same enqueue_first_for call
    # once it has. s3 has no folder to confirm and keeps its first scan at sign-up; chunk_remote
    # never scans. Where the sign-up lands is the redirect's test, not this one.
    test "on a fresh install the first sign-up scans nothing on share and still scans on s3" do
      Setting.forget(Tinkerex::LibraryRoot::KEY)
      adapter = FileLayer.current
      if !adapter.is_a?(FileLayer::Share) && adapter.capabilities.scannable?
        assert_enqueued_with(job: Library::ScanJob) { sign_up("owner@example.com") }
      else
        assert_no_enqueued_jobs(only: Library::ScanJob) { sign_up("owner@example.com") }
      end
      assert User.find_by!(email: "owner@example.com").confirmed?, "the owner is still created, confirmed"
    end

    test "a second sign-up on a closed server creates nothing" do
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { User.count } do
        sign_up("stranger@example.com")
        assert_response :forbidden
      end
    end

    test "with registration open the usual confirmable flow is untouched" do
      ENV["REGISTRATION"] = "open"
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_emails 1 do
        sign_up("second@example.com")
      end
      assert_not User.find_by!(email: "second@example.com").confirmed?
    end
  end
end
