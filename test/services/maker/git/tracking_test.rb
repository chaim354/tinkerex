require "test_helper"

module Maker
  module Git
    class TrackingTest < ActiveSupport::TestCase
      # `part.scad` rides the TEXT_EXTS axis, not TEXT_ROLES: its ROLE is `cad_source` (it belongs
      # in `cad/` beside the `.f3d`), and it is text anyway. That is exactly why this module asks
      # `FileAttachment.text?` rather than testing a role list -- a role list answers `pointer`
      # here, which would commit OpenSCAD source as an opaque blob.
      test "text roles are tracked as content" do
        %w[main.c notes.md config.yml part.scad job.gcode script.rb].each do |name|
          assert_equal :content, Maker::Git::Tracking.mode_for(name), "#{name} should be content"
        end
      end

      test "model and cad roles are tracked as pointers" do
        %w[bracket.stl body.step case.3mf art.lbrn2 photo.jpg bundle.zip].each do |name|
          assert_equal :pointer, Maker::Git::Tracking.mode_for(name), "#{name} should be a pointer"
        end
      end

      # Extensionless text is a SEPARATE AXIS (§14d). File.extname("LICENSE") is "", so no entry in
      # an extension table can ever reach these -- and a repo's root is full of exactly them.
      test "extensionless text files are content" do
        %w[LICENSE Makefile README makefile].each do |name|
          assert_equal :content, Maker::Git::Tracking.mode_for(name), "#{name} should be content"
        end
      end

      # THE DERIVATION IS THE POINT: a new extension added to ROLE_BY_EXT must get an answer here
      # without anyone editing this file.
      test "every extension in ROLE_BY_EXT gets an answer, so a new one cannot fall through" do
        Maker::FileAttachment::ROLE_BY_EXT.each_key do |ext|
          mode = Maker::Git::Tracking.mode_for("file.#{ext}")
          assert_includes [ :content, :pointer ], mode, "#{ext} has no tracking mode"
        end
      end

      test "a pointer body names the content hash and size" do
        user = User.create!(email: "tracking-#{SecureRandom.hex(4)}@example.com")
        node = user.nodes.create!(node_id: SecureRandom.uuid, name: "b.stl", kind: "file",
                                  content_hash: "sha256:#{'a' * 64}", size: 4_000_000)
        body = Maker::Git::Tracking.pointer_for(node)

        assert_match(/\Aversion tinkerex\/v1\n/, body)
        assert_match(/^oid sha256:a{64}$/, body)
        assert_match(/^size 4000000$/, body)
      end
    end
  end
end
