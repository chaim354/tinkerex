require "test_helper"

module Web
  # A file that belongs to a Maker::Model is part of a BUNDLE — an imported model is its STL plus
  # instructions plus cover plus source archive. Attaching one of them to a project attaches the
  # whole model and moves nothing, rather than pulling one file out of Models/<slug>/ and leaving
  # the rest behind.
  #
  # MOVES NOTHING IS THE POINT, AND IT IS WHY THIS IS BACKEND-NEUTRAL WHERE TASK 3 IS NOT: the
  # rejected alternative (move the model's whole folder into the project) is refused outright by
  # FileLayer::S3#move, which has no directory to move and no rename. A rule that relocates no
  # bytes behaves identically on all three backends by construction.
  #
  # Still PINNED TO CHUNK, for the sibling tests that exercise the Task-3 move this rule sits
  # beside (attach_auto_move_test.rb explains why the move needs a real chunk store).
  class AttachModelBundleTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = User.create!(email: "amb-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")

      # A model as the importer leaves it: a folder, three files in it, all three attached.
      @model = @user.maker_models.create!(title: "Benchy")
      @folder = @model.ensure_library_folder!(@user)
      @hull  = model_file("hull.stl")
      @docs  = model_file("instructions.pdf")
      @cover = model_file("cover.png")
    end

    def model_file(name)
      node = @user.nodes.create!(node_id: "m-#{name}", name:, kind: "file",
                                 parent_node_id: @folder.node_id)
      @model.file_attachments.create!(user: @user, node_id: node.node_id,
                                      role: Maker::FileAttachment.role_for(name))
      node
    end

    def project_names
      @project.file_attachments.map { |a| @user.nodes.find_by(node_id: a.node_id).name }.sort
    end

    test "attaching one of a model's files attaches the whole model" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }

      assert_equal %w[cover.png hull.stl instructions.pdf], project_names
    end

    test "and moves nothing — the model's folder is left intact" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }

      [ @hull, @docs, @cover ].each do |node|
        assert_equal @folder.node_id, node.reload.parent_node_id,
                     "#{node.name} must stay in the model folder"
      end
      assert_empty @user.changelog_entries.where(op: "move"),
                   "a model bundle relocates NO bytes — that is what makes it backend-neutral"
    end

    test "the notice says the whole model came along" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }
      assert_match(/Benchy/, flash[:notice])
      assert_match(/3 files/i, flash[:notice])
    end

    test "roles are derived per file, not copied from the file that was attached" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }

      roles = @project.file_attachments.to_h { |a|
        [ @user.nodes.find_by(node_id: a.node_id).name, a.role ]
      }
      assert_equal({ "hull.stl" => "model", "instructions.pdf" => "instructions",
                     "cover.png" => "image" }, roles)
    end

    test "re-attaching the same model twice does not duplicate the bundle" do
      2.times { post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id } }
      assert_equal 3, @project.file_attachments.count
    end

    test "a model file already attached to the project individually is not duplicated" do
      @project.file_attachments.create!(user: @user, node_id: @cover.node_id, role: "image")
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }
      assert_equal 3, @project.file_attachments.count
    end

    # maker_file_attachments has no uniqueness index, so a model CAN hold two rows for one file.
    # find_or_create_by! already stops the duplicate row here; what it does not stop is counting
    # that file twice in the sentence the user reads.
    test "a duplicate model attachment row does not inflate the count" do
      @model.file_attachments.create!(user: @user, node_id: @hull.node_id, role: "model")

      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }

      assert_equal 3, @project.file_attachments.count
      assert_match(/3 files/i, flash[:notice])
    end

    # A model file the user deleted from the library must not be resurrected as a project
    # attachment: the bundle is "the model's LIVE files", and an attachment pointing at a
    # tombstone renders as a broken row on the project page.
    test "a tombstoned member is left out of the bundle" do
      @docs.update!(deleted: true)

      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }

      assert_equal %w[cover.png hull.stl], project_names
      assert_match(/2 files/i, flash[:notice])
    end

    test "attaching from the file page still returns to the file page" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id,
                                       return_to: "file" }
      assert_redirected_to file_path(@hull.node_id)
    end

    test "a plain library file still MOVES — Task 3's rule is untouched" do
      loose = @user.nodes.create!(node_id: "f-loose", name: "bracket.stl", kind: "file")
      post attachments_path, params: { project_id: @project.slug, node_id: "f-loose" }

      folder = @user.nodes.present.find_by!(name: @project.slug, kind: "dir")
      assert_equal folder.node_id, loose.reload.parent_node_id
    end

    test "a model file whose model attachment was removed is a plain file again" do
      @model.file_attachments.find_by(node_id: @hull.node_id).destroy!
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id }

      folder = @user.nodes.present.find_by!(name: @project.slug, kind: "dir")
      assert_equal folder.node_id, @hull.reload.parent_node_id,
                   "membership is the ATTACHMENT, not the folder it happens to sit in"
      assert_equal 1, @project.file_attachments.count
    end

    # ANOTHER USER'S MODEL MUST NOT CLAIM THIS USER'S FILE. The attachments table is keyed by a
    # bare node_id string with no FK, so an unscoped lookup would find a foreign row pointing at
    # the same id and attach that stranger's whole bundle into this project.
    test "a foreign model's attachment row does not turn this file into a bundle" do
      other = User.create!(email: "amb-other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      loose = @user.nodes.create!(node_id: "f-shared", name: "bracket.stl", kind: "file")
      other.maker_models.create!(title: "Theirs")
           .file_attachments.create!(user: other, node_id: loose.node_id, role: "model")

      post attachments_path, params: { project_id: @project.slug, node_id: "f-shared" }

      refute_nil loose.reload.parent_node_id,
                 "the foreign row must not make this a bundle — a plain file MOVES"
      folder = @user.nodes.present.find_by!(name: @project.slug, kind: "dir")
      assert_equal folder.node_id, loose.parent_node_id
      assert_equal 1, @project.file_attachments.count
    end

    # The lookup asks for Maker::Model rows specifically. Without that filter it would find the
    # file's PROJECT attachment, call that project a "model", and drag every file of the project
    # the user attached it to last week into this one.
    test "a file already attached to a PROJECT is not mistaken for a bundle" do
      bench = @user.maker_projects.create!(name: "Bench")
      @user.nodes.create!(node_id: "f-a", name: "a.stl", kind: "file")
      @user.nodes.create!(node_id: "f-b", name: "b.stl", kind: "file")
      bench.file_attachments.create!(user: @user, node_id: "f-a", role: "model")
      bench.file_attachments.create!(user: @user, node_id: "f-b", role: "model")

      post attachments_path, params: { project_id: @project.slug, node_id: "f-a" }

      assert_equal %w[a.stl], project_names, "only the file the user named"
    end

    test "the JSON door reports the bundle" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id },
           as: :json
      assert_response :created
      assert_equal "model_bundle", response.parsed_body["relocation"]
      assert_equal @hull.node_id, response.parsed_body["node_id"]
    end

    # Same argument as the single-file door's 200-vs-201: the second attach creates nothing, so
    # claiming Created would be a lie to the only caller that reads the status.
    test "a JSON re-attach of an already-attached bundle is 200, not 201" do
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id },
           as: :json
      post attachments_path, params: { project_id: @project.slug, node_id: @hull.node_id },
           as: :json
      assert_response :ok
    end
  end
end
