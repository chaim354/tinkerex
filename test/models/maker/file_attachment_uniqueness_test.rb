require "test_helper"

module Maker
  # The app layer already refuses a duplicate attach — measured: two sequential POSTs of the same
  # node to the same project create ONE row. This pins the DATABASE constraint, which closes the
  # remaining window: two concurrent requests both passing the app-level check before either
  # commits. A double-clicked button or a retried fetch() is enough.
  class FileAttachmentUniquenessTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "uniq@example.com", confirmed_at: Time.current,
                           omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "P", status: "active")
      @user.nodes.create!(node_id: "n1", name: "n1.stl", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "the same node cannot be attached to the same project twice" do
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")

      assert_raises ActiveRecord::RecordNotUnique do
        # insert_all! skips validations and callbacks ON PURPOSE: the point is that the DATABASE
        # refuses it, which is the only layer a concurrent racer cannot slip past. Going through
        # the model would only re-test the app-level guard that already works.
        Maker::FileAttachment.insert_all!([ {
          user_id: @user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id: "n1", role: "model", position: 0,
          created_at: Time.current, updated_at: Time.current
        } ])
      end
    end

    test "the same node CAN be attached to two different projects" do
      other = @user.maker_projects.create!(name: "Q", status: "active")
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      assert_nothing_raised do
        other.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      end
    end

    test "two different nodes CAN be attached to the same project" do
      @user.nodes.create!(node_id: "n2", name: "n2.stl", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      assert_nothing_raised do
        @project.file_attachments.create!(user: @user, node_id: "n2", role: "model")
      end
    end

    test "the same node CAN be attached to a project and to a model" do
      # attachable_type is part of the key, so a polymorphic sibling is not a duplicate. Without
      # this case a too-narrow index (user_id + node_id alone) would look correct.
      model = @user.maker_models.create!(title: "M", slug: "m")
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      assert_nothing_raised do
        model.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      end
    end

    test "two different users CAN each attach their own node of the same id" do
      # node_id is only unique per user, so the index must include user_id or a second user
      # attaching their own "n1" would collide with the first user's.
      other_user = User.create!(email: "uniq2@example.com", confirmed_at: Time.current,
                                omniauth_signup: true)
      other_project = other_user.maker_projects.create!(name: "R", status: "active")
      other_user.nodes.create!(node_id: "n1", name: "theirs.stl", kind: "file", size: 1,
                               mtime: 1_700_000_000_000_000_000)

      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      assert_nothing_raised do
        other_project.file_attachments.create!(user: other_user, node_id: "n1", role: "model")
      end
    end
  end
end
