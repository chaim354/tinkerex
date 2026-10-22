require "test_helper"

module Web
  # THE TOP BAR'S UPLOAD CARRIES THE UNPACK DOORS ON EITHER FLOW (2026-10-21). Two wire shapes behind
  # one button (layouts/_topbar_upload.html.erb): the share/s3 multipart form with the zip-upload
  # controller, the chunk_remote uploader section with three more values. BRANCHED ON
  # port_writable? because a form-shaped assertion is red only on the chunk_remote leg — the trap
  # files_toolbar_test.rb's idiom exists for. Runs on the ambient backend; node rows only.
  class TopbarZipMarkupTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "tzm-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    teardown { FileLayer.reset! }

    test "the top bar's Upload carries the unpack doors and the model extensions" do
      get files_path
      assert_response :success
      exts = Maker::FileAttachment::MODEL_EXTS.to_json

      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar form[data-controller~='zip-upload']" \
                      "[data-zip-upload-unpack-url-value=?][data-zip-upload-unpacked-url-value=?]" \
                      "[data-zip-upload-create-url-value=?][data-zip-upload-model-exts-value=?]",
                      files_unpack_folder_path, files_unpacked_path, files_path, exts
        assert_select "header.topbar input#topbar_upload_file[data-action~='change->zip-upload#change']"
        assert_select "header.topbar input#topbar_upload_file[onchange]", count: 0
        assert_select "header.topbar input[name='parent_node_id'][data-zip-upload-target='parent']"
      else
        assert_select "header.topbar section[data-controller~='uploader']" \
                      "[data-uploader-unpack-url-value=?][data-uploader-unpacked-url-value=?]" \
                      "[data-uploader-model-exts-value=?]",
                      files_unpack_folder_path, files_unpacked_path, exts
      end
    end

    test "MODEL_EXTS is every extension the vocabulary files as a model" do
      assert_includes Maker::FileAttachment::MODEL_EXTS, "stl"
      assert_includes Maker::FileAttachment::MODEL_EXTS, "3mf"
      assert_includes Maker::FileAttachment::MODEL_EXTS, "step"
      refute_includes Maker::FileAttachment::MODEL_EXTS, "zip"
      assert(Maker::FileAttachment::MODEL_EXTS.all? { |e| Maker::FileAttachment.role_for("x.#{e}") == "model" })
    end
  end
end
