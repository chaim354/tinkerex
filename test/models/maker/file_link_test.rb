require "test_helper"

module Maker
  # Stage 4, S4-8: one file's tie to another. The model's whole job is to hold two BARE node-id
  # strings honestly — no foreign key, no liveness, no ownership check (Maker::Note and
  # Maker::FileAttachment set that convention and the plan's Amendment 2 argues it). What it does
  # own is the kind vocabulary, the self-link refusal, and the pair's uniqueness.
  class FileLinkTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "link-#{SecureRandom.hex(4)}@example.com")
    end

    def link(from: "n-export", to: "n-source", kind: "derived_from", user: @user)
      user.maker_file_links.new(from_node_id: from, to_node_id: to, kind:)
    end

    test "both kinds are valid and nothing else is" do
      assert_equal %w[derived_from photo_of], Maker::FileLink::KINDS
      Maker::FileLink::KINDS.each { |k| assert link(kind: k).valid?, "#{k} should be a kind" }
      refute link(kind: "inspired_by").valid?
      refute link(kind: "").valid?
    end

    # A NODE THIS USER DOES NOT OWN, AND A NODE THAT DOES NOT EXIST, ARE BOTH VALID ROWS — on
    # purpose. Ownership is the DOOR's question (Files::LinksController, Tools::AddonsController,
    # the measure save), and liveness is the READER's (nodes.present at render time). Putting
    # either here would refuse a row whose file was tombstoned an hour ago, which is exactly the
    # state Maker::AttachmentReaper exists to clean up on a schedule instead.
    test "a node that is absent, tombstoned or another user's is still a valid row" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "theirs.stl", kind: "file")
      assert link(from: "never-existed", to: "n-theirs").valid?
    end

    test "a file cannot be derived from itself" do
      row = link(from: "n-same", to: "n-same")
      refute row.valid?
      assert_includes row.errors.full_messages.join, "same file"
    end

    # ONE PAIR PER KIND, ENFORCED BY THE INDEX AND NOT BY A VALIDATION. A `validates :uniqueness`
    # would be a second SELECT on every write and would still lose a race; the doors treat
    # RecordNotUnique as "this request's intent is already satisfied" (the argument
    # Projects::EntryPhotosController#create already carries for maker_file_attachments).
    test "the same pair and kind cannot be stored twice, while the other kind and the reverse can" do
      link.save!
      assert_raises(ActiveRecord::RecordNotUnique) { link.save! }
      assert link(kind: "photo_of").save, "a different kind on the same pair is a different fact"
      assert link(from: "n-source", to: "n-export").save, "the reverse pair is a different fact"
    end

    test "another user may hold the identical pair" do
      link.save!
      other = User.create!(email: "twin-#{SecureRandom.hex(4)}@example.com")
      assert link(user: other).save
    end

    # `touching` IS WHAT MAKES THE FILE PAGE ONE QUERY INSTEAD OF TWO (FilesController#show).
    test "touching finds a node at either end and nothing else" do
      a = link(from: "n-a", to: "n-b").tap(&:save!)
      b = link(from: "n-b", to: "n-c").tap(&:save!)
      link(from: "n-x", to: "n-y").save!
      assert_equal [ a, b ].map(&:id).sort, @user.maker_file_links.touching("n-b").pluck(:id).sort
    end

    test "destroying the user takes its links" do
      link.save!
      assert_difference "Maker::FileLink.count", -1 do
        @user.destroy!
      end
    end
  end
end
