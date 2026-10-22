require "test_helper"

module Web
  # Files::LinksController (stage 4, S4-8): one door, two kinds, and the DIRECTION decided by the
  # server from `kind` rather than posted by the form — which is the property that makes an
  # inverted link unreachable rather than merely unlikely.
  class FileLinksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "fl-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @subject = file!("n-subject", "lid.stl")
      @source  = file!("n-source", "lid.lbrn2")
      @photo   = file!("n-photo", "cut.png")
    end

    def file!(id, name)
      @user.nodes.create!(node_id: id, name:, kind: "file", mtime: 1_000_000_000, size: 10)
    end

    test "derived_from points FROM the page you are on TO the file you picked" do
      post file_links_path(@subject.node_id),
           params: { kind: "derived_from", other_node_id: @source.node_id }
      assert_redirected_to file_path(@subject.node_id)
      link = @user.maker_file_links.sole
      assert_equal [ @subject.node_id, @source.node_id, "derived_from" ],
                   [ link.from_node_id, link.to_node_id, link.kind ]
    end

    # THE REVERSAL IS THE WHOLE REASON THE DOOR TAKES `kind` AND NOT `from`/`to`: a photo_of's
    # subject is the file being DEPICTED, so the picked image is the link's FROM.
    test "photo_of points FROM the picked image TO the page you are on" do
      post file_links_path(@subject.node_id),
           params: { kind: "photo_of", other_node_id: @photo.node_id }
      link = @user.maker_file_links.sole
      assert_equal [ @photo.node_id, @subject.node_id, "photo_of" ],
                   [ link.from_node_id, link.to_node_id, link.kind ]
    end

    # AN iPHONE ORIGINAL IS AN IMAGE TO THIS DOOR (tinkerex#285): `.heic` carries the image role
    # since 2026-09-08, so story 3.3's headline user — someone photographing a finished part — can
    # attach the file the phone actually wrote.
    test "an iPhone original is accepted as a photo" do
      original = file!("n-heic", "IMG_0001.heic")
      post file_links_path(@subject.node_id),
           params: { kind: "photo_of", other_node_id: original.node_id }
      assert_redirected_to file_path(@subject.node_id)
      link = @user.maker_file_links.sole
      assert_equal [ original.node_id, @subject.node_id, "photo_of" ],
                   [ link.from_node_id, link.to_node_id, link.kind ]
    end

    test "a photo_of whose target is not an image is refused by name, not silently accepted" do
      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id),
             params: { kind: "photo_of", other_node_id: @source.node_id }
      end
      assert_equal "Only an image can be a photo of a file.", flash[:alert]
    end

    test "an unknown kind, a directory, a tombstone and another user's file are all refused" do
      dir = @user.nodes.create!(node_id: "d-x", name: "x", kind: "dir")
      @user.nodes.create!(node_id: "n-tomb", name: "t.stl", kind: "file", deleted: true)
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "theirs.stl", kind: "file")

      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id), params: { kind: "inspired_by", other_node_id: @source.node_id }
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: dir.node_id }
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: "n-tomb" }
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: "n-theirs" }
        post file_links_path("n-theirs"), params: { kind: "derived_from", other_node_id: @source.node_id }
      end
    end

    test "linking the same pair twice succeeds without raising" do
      2.times do
        post file_links_path(@subject.node_id),
             params: { kind: "derived_from", other_node_id: @source.node_id }
        assert_response :redirect
      end
      assert_equal 1, @user.maker_file_links.count
    end

    test "a file cannot be linked to itself" do
      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id),
             params: { kind: "derived_from", other_node_id: @subject.node_id }
      end
      assert_match(/same file/, flash[:alert])
    end

    test "the JSON door answers 201 with the row's id, and 422 with a sentence" do
      post file_links_path(@subject.node_id), as: :json,
           params: { kind: "derived_from", other_node_id: @source.node_id }
      assert_response :created
      assert_equal @user.maker_file_links.sole.id, response.parsed_body["id"]

      post file_links_path(@subject.node_id), as: :json,
           params: { kind: "derived_from", other_node_id: "nope" }
      assert_response :unprocessable_entity
      assert_equal "Pick a file in your library.", response.parsed_body["error"]
    end

    test "destroy removes the link and returns to the page the button was on" do
      link = @user.maker_file_links.create!(from_node_id: @subject.node_id,
                                            to_node_id: @source.node_id, kind: "derived_from")
      delete file_link_path(link), params: { from: @source.node_id }
      assert_redirected_to file_path(@source.node_id)
      assert_equal 0, @user.maker_file_links.count
    end

    # 404 AND THE ROW SURVIVES, which is notes_test.rb's idiom for the same shape. The plan wrote
    # `assert_raises(ActiveRecord::RecordNotFound)`; that can never pass here, because the test env
    # sets `show_exceptions = :rescuable` and the raise is turned into a response before the test
    # sees it. The survival assertion is what carries the weight either way.
    test "another user's link cannot be destroyed" do
      other = User.create!(email: "o2-#{SecureRandom.hex(4)}@example.com")
      link = other.maker_file_links.create!(from_node_id: "a", to_node_id: "b", kind: "photo_of")
      delete file_link_path(link)
      assert_response :not_found
      assert Maker::FileLink.exists?(link.id), "another user's link must survive"
    end

    test "both actions require a session" do
      delete destroy_user_session_path
      assert_no_difference "Maker::FileLink.count" do
        post file_links_path(@subject.node_id), params: { kind: "derived_from", other_node_id: @source.node_id }
      end
      assert_redirected_to new_user_session_path
    end
  end
end
