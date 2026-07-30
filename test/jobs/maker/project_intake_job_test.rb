require "test_helper"

module Maker
  class ProjectIntakeJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      pin_file_layer_backend("chunk")
      @user = User.create!(email: "pij-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
    end

    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent, size: 1, content_hash: SecureRandom.hex(8))
    end

    test "perform attaches and files" do
      node = file("panel.svg")
      Maker::ProjectIntakeJob.perform_now(user_id: @user.id)
      assert @project.file_attachments.exists?(node_id: node.node_id)
      assert_equal "design", @user.nodes.find_by(node_id: node.reload.parent_node_id).name
    end

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
    test "a missing user is discarded, not failed" do
      assert_nothing_raised do
        perform_enqueued_jobs do
          Maker::ProjectIntakeJob.perform_later(user_id: 999_999_999)
        end
      end
    end

    # THE GATE IS ON THE FAN-OUT, NOT ON #perform — the house rule Library::ScanJob states: a
    # `return unless` inside #perform would make an operator's explicit run silently do nothing.
    test "sweep_all! enqueues for a chunk deployment" do
      assert_enqueued_with(job: Maker::ProjectIntakeJob) do
        Maker::ProjectIntakeJob.sweep_all!
      end
    end

    # On a SCANNED backend Library::ScanJob is already the caller. Running both would reintroduce
    # the scan overlap the design places this call to prevent.
    test "sweep_all! declines on a scannable backend" do
      root = Dir.mktmpdir("pij-share")
      begin
        FileLayer.current = FileLayer::Share.new(root:)
        assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
          Maker::ProjectIntakeJob.sweep_all!
        end
      ensure
        FileLayer.reset!
        FileUtils.remove_entry(root)
      end
    end

    # #perform has NO gate, so an explicit run works on any backend.
    test "perform still performs on a scannable backend" do
      node = file("panel.svg")
      assert_nothing_raised { Maker::ProjectIntakeJob.perform_now(user_id: @user.id) }
      assert @project.file_attachments.exists?(node_id: node.node_id)
    end
  end
end
