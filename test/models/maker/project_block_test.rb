require "test_helper"

module Maker
  # A CONTENT BLOCK (2026-09-09, content blocks; spec §4): one row per block, three kinds, the
  # fields checked against the kind so a link without a URL or an image without a file cannot be
  # saved by any door.
  class ProjectBlockTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "blocks-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple", confirmed_at: Time.current)
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    def block(**attrs) = @project.blocks.new(user: @user, **attrs)

    test "a key is minted when none is given, twelve hex characters, unique per project" do
      a = block(kind: "text", body: "hello")
      assert a.save, a.errors.full_messages.inspect
      assert_match(/\A[0-9a-f]{12}\z/, a.key)
      assert_equal "block:#{a.key}", a.layout_key
      b = block(kind: "text", body: "again", key: a.key)
      refute b.valid?
      assert_includes b.errors[:key], "has already been taken"
    end

    test "text needs a heading or a body, link needs a URL and a title, image needs a file" do
      refute block(kind: "text").valid?
      assert block(kind: "text", heading: "Why").valid?
      assert block(kind: "text", body: "Because.").valid?
      refute block(kind: "link", url: "https://example.com").valid?, "a link needs a title"
      refute block(kind: "link", heading: "Site").valid?, "a link needs a URL"
      assert block(kind: "link", url: "https://example.com", heading: "Site").valid?
      refute block(kind: "image").valid?
      assert block(kind: "image", node_id: SecureRandom.uuid).valid?
      refute block(kind: "video", body: "x").valid?
    end

    test "a link URL is http or https, nothing else, in either case, under 2 KB" do
      %w[https://a.example/p?q=1 http://b.example HTTPS://EXAMPLE.COM].each { |u| assert block(kind: "link", url: u, heading: "t").valid?, u }
      [ "javascript:alert(1)", "JAVASCRIPT:alert(1)", "ftp://x", "example.com", "https://", "https://x y" ].each do |u|
        b = block(kind: "link", url: u, heading: "t")
        refute b.valid?, u
        assert_includes b.errors[:url], "must be an http or https URL", u
      end
      long = block(kind: "link", url: "https://a.example/#{'x' * 2048}", heading: "t")
      refute long.valid?
      assert long.errors[:url].any?, "a URL over URL_MAX is refused on every kind"
      refute block(kind: "text", body: "x", url: "https://a.example/#{'x' * 2048}").valid?
    end

    test "a malformed URL and a missing title are both reported" do
      b = block(kind: "link", url: "https://[bad")
      refute b.valid?
      assert_includes b.errors[:url], "must be an http or https URL"
      assert_includes b.errors[:heading], "is required for a link"
    end

    test "lengths are capped and whitespace is collapsed" do
      refute block(kind: "text", heading: "x" * 81).valid?
      assert block(kind: "text", heading: "x" * 80).valid?
      refute block(kind: "text", body: "x" * (20 * 1024 + 1)).valid?
      refute block(kind: "link", url: "https://a.example", heading: "t", line: "x" * 201).valid?
      refute block(kind: "image", node_id: "n", caption: "x" * 201).valid?
      b = block(kind: "text", heading: "  Why  a\n shade ")
      assert b.valid?
      assert_equal "Why a shade", b.heading
    end

    test "a block belongs to its project's owner" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple", confirmed_at: Time.current)
      b = @project.blocks.new(user: other, kind: "text", body: "x")
      refute b.valid?
      assert_includes b.errors[:project_id], "must reference your own project"
    end

    test "destroying the project destroys its blocks" do
      block(kind: "text", body: "x").save!
      assert_difference -> { Maker::ProjectBlock.count }, -1 do
        @project.destroy!
      end
    end
  end
end
