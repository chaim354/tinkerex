require "test_helper"

module Maker
  # The attach policy, one rule per test, WITHOUT HTTP.
  #
  # THIS FILE IS THE POINT OF THE EXTRACTION. The rules used to live inline in
  # Projects::AttachmentsController#create, where the only way to ask "does a model's file stay
  # put?" was to drive a request — so when #relocate was added it called the move directly, below
  # every rule, and three of them silently did not apply. A rule that can be asked a question
  # directly is a rule the next door can be checked against.
  #
  # PINNED TO CHUNK, like the web tests: the rules are backend-neutral, but the move they gate is
  # Maker::MoveNode's two-door branch, and on share/s3 the port would want a real disk or bucket
  # behind every fixture. The doors themselves are covered per-backend in move_node_test.rb.
  class AttachToProjectTest < ActiveSupport::TestCase
    setup do
      pin_file_layer_backend("chunk")
      @user = User.create!(email: "atp-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @lamp = @user.maker_projects.create!(name: "Desk Lamp")
      @bench = @user.maker_projects.create!(name: "Bench")
      @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
    end

    def service(project = @lamp) = Maker::AttachToProject.new(user: @user, project:)

    def lamp_folder = @lamp.ensure_library_folder!(@user)

    # --- #refusal_for: the rules themselves ---------------------------------------

    test "an ordinary unattached file has nothing standing in its way" do
      assert_nil service.refusal_for(@node)
    end

    # A directory has no place in a project folder, and FileLayer::S3#move refuses one outright
    # (movable_file!) — so allowing it would be a policy that works on share/chunk and 422s on s3.
    test "a directory is refused" do
      dir = @user.nodes.create!(node_id: "d-1", name: "cad", kind: "dir")
      assert_equal :not_a_file, service.refusal_for(dir)
    end

    # THE RULE #relocate USED TO MISS. An imported model is its STL plus instructions plus cover,
    # curated into Models/<slug>/; moving one out guts the folder.
    test "a file that belongs to a model is refused" do
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      assert_equal :model_bundle, service.refusal_for(@node)
    end

    # MEMBERSHIP IS THE ATTACHMENT, NOT THE FOLDER — the rule reads the row, so a file sitting in
    # Models/widget/ without one is an ordinary file, and a member moved out of that folder is
    # still a member. Both directions, because the wrong test (checking the parent) would pass the
    # first half and fail the second.
    test "model membership is the attachment row, not where the bytes sit" do
      model = @user.maker_models.create!(title: "Widget")
      folder = model.ensure_library_folder!(@user)

      stray = @user.nodes.create!(node_id: "f-stray", name: "stray.stl", kind: "file",
                                  parent_node_id: folder.node_id)
      assert_nil service.refusal_for(stray), "sitting in the folder does not make it a member"

      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_equal :model_bundle, service.refusal_for(@node),
                   "and a member that lives elsewhere is still a member"
    end

    # SCOPED THROUGH THE ATTACHMENTS TABLE, which keys files by a bare node_id string with no FK —
    # so an unscoped lookup would find another user's row naming the same id and refuse (or worse,
    # attach) on the strength of a stranger's model.
    test "another user's model attachment does not claim my file" do
      other = User.create!(email: "atpo-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      other.maker_models.create!(title: "Theirs")
           .file_attachments.create!(user: other, node_id: "f-1", role: "model")

      assert_nil service.refusal_for(@node)
    end

    test "a file another project already claims is refused" do
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_equal :attached_elsewhere, service.refusal_for(@node)
    end

    test "this project's own attachment is not 'elsewhere'" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_nil service.refusal_for(@node)
    end

    # --- #relocate: the rules, applied ---------------------------------------------

    # THE ENDPOINT FINISHES AN ATTACH, so there has to be one. Without this, a POST to a project
    # the user never attached anything to moved the file in AND minted the project's folder.
    test "relocate refuses when there is no attachment to finish, and creates no folder" do
      assert_equal :not_attached, service(@bench).relocate(@node)
      assert_nil @node.reload.parent_node_id
      assert_nil @bench.reload.folder_node_id
    end

    test "relocate applies every refusal, and moves nothing while doing it" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      assert_equal :model_bundle, service.relocate(@node)
      assert_nil @node.reload.parent_node_id

      model.file_attachments.destroy_all
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_equal :attached_elsewhere, service.relocate(@node)
      assert_nil @node.reload.parent_node_id
      assert_empty @user.changelog_entries.where(op: "move")
    end

    test "relocate moves an attached file under the requested name" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      assert_equal :moved, service.relocate(@node, new_name: "bracket (2).stl")
      @node.reload
      assert_equal lamp_folder.node_id, @node.parent_node_id
      assert_equal "bracket (2).stl", @node.name
      assert_equal "f-1", @node.node_id, "the node_id is what every attachment points at"
    end

    # ONE SYMBOL PER OUTCOME, because the caller words a different sentence for each. :bad_name is
    # separate from :unavailable on purpose — "try again later" is false for a name that can never
    # work, and move_node.rb asked for the split by name.
    test "relocate names each move outcome" do
      @lamp.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      @user.nodes.create!(node_id: "f-2", name: "taken.stl", kind: "file",
                          parent_node_id: lamp_folder.node_id)

      assert_equal :conflict, service.relocate(@node, new_name: "taken.stl")
      assert_equal :bad_name, service.relocate(@node, new_name: "../escape.stl")
      assert_equal :bad_name, service.relocate(@node, new_name: [ "a/b.stl" ])
      assert_nil @node.reload.parent_node_id, "none of those may have moved anything"

      assert_equal :moved, service.relocate(@node)
      assert_equal :already_there, service.relocate(@node),
                   "same folder, same name — a no-op the sync engine must not be told about"
      assert_equal 1, @user.changelog_entries.where(op: "move").count
    end

    # --- #call: the attach door -----------------------------------------------------

    test "attaching an unattached file creates the row and moves it in" do
      result = service.call(@node)

      assert_equal :moved, result.relocation
      assert result.created
      assert_nil result.model
      assert_equal [ "f-1" ], result.attachments.map(&:node_id)
      assert_equal lamp_folder.node_id, @node.reload.parent_node_id
    end

    # nil, NOT a refusal symbol: "not moved" and "never tried" are different facts, and #create's
    # JSON door reports the second as a present-and-null key.
    test "a refused move reports nil relocation, not the reason" do
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      result = service.call(@node)

      assert_nil result.relocation
      assert_equal 1, @lamp.file_attachments.count, "…but the attach still happens"
    end

    test "attaching twice creates nothing the second time" do
      service.call(@node)
      result = service.call(@node)

      assert_not result.created, "claiming Created for a row that already existed would be a lie"
      assert_equal 1, @lamp.file_attachments.count
    end

    # Models::AttachmentsController does not filter by kind, so a dir CAN belong to a model — and
    # #attach_bundle keeps live FILES only, so the triggering node was absent from its own result:
    # "Attached 0 files from Widget." on the HTML door and `undefined method 'node_id' for nil` on
    # the JSON one. Both reproduced before the fix.
    test "a directory that belongs to a model attaches as itself, not as a bundle" do
      dir = @user.nodes.create!(node_id: "d-1", name: "cad", kind: "dir")
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "d-1", role: "other")
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      result = service.call(dir)

      assert_nil result.model, "a dir has nothing to relocate under any rule"
      assert_equal [ "d-1" ], result.attachments.map(&:node_id)
      assert_nil result.relocation
      assert_equal "d-1", result.attachments.first.node_id,
                   "the triggering node must be in its own result — the JSON door reads it"
    end

    test "attaching a model's file brings the whole bundle and moves nothing" do
      model = @user.maker_models.create!(title: "Widget")
      folder = model.ensure_library_folder!(@user)
      %w[widget.stl instructions.pdf cover.png].each_with_index do |name, i|
        @user.nodes.create!(node_id: "m-#{i}", name:, kind: "file", parent_node_id: folder.node_id)
        model.file_attachments.create!(user: @user, node_id: "m-#{i}", role: "other")
      end

      result = service.call(@user.nodes.find_by(node_id: "m-0"))

      assert_equal :model_bundle, result.relocation
      assert_equal model, result.model
      assert_equal %w[m-0 m-1 m-2], result.attachments.map(&:node_id).sort
      assert_equal folder.node_id, @user.nodes.find_by(node_id: "m-0").parent_node_id
      assert_empty @user.changelog_entries.where(op: "move")
      # The role is derived PER FILE: a bundle is a PDF and a PNG and an STL, so copying the
      # triggering file's role would label the instructions "model".
      assert_equal %w[image instructions model],
                   result.attachments.map(&:role).sort
    end
  end
end
