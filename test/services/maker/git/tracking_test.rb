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

      # ---- the size ceiling ------------------------------------------------------------------
      #
      # ROLE ALONE CANNOT SEE BYTES: `notes.md` and a 400 MB `notes.md` are the same filename, and
      # only one of them belongs in a history git cannot prune without rewriting every commit id
      # the maker has seen.

      test "a text file over the size ceiling becomes a pointer whatever its name says" do
        over = Maker::Git::Tracking::MAX_CONTENT_BYTES + 1

        %w[notes.md main.c job.gcode part.scad LICENSE].each do |name|
          assert_equal :pointer, Maker::Git::Tracking.mode_for(name, size: over),
                       "#{name} is over the ceiling and must not enter history as content"
        end
      end

      # THE BOUNDARY IS `>`, NOT `>=`, and it is asserted because an off-by-one here is invisible:
      # both spellings pass every probe taken far from the edge, and this is the only test that can
      # tell them apart.
      test "a text file exactly at the size ceiling is still content" do
        assert_equal :content,
                     Maker::Git::Tracking.mode_for("notes.md",
                                                   size: Maker::Git::Tracking::MAX_CONTENT_BYTES)
      end

      # THE CEILING DEMOTES, IT NEVER PROMOTES. A binary under it is still a pointer -- otherwise
      # "under the ceiling" would quietly become the whole test and every small STL would land in
      # the history as content.
      test "the ceiling only demotes: a small binary is still a pointer" do
        assert_equal :content, Maker::Git::Tracking.mode_for("notes.md", size: 1_024)
        assert_equal :pointer, Maker::Git::Tracking.mode_for("bracket.stl", size: 1_024)
      end

      # AN ABSENT SIZE MEANS "I DO NOT KNOW", NEVER "IT IS HUGE". `VersionHistory#for_path`,
      # `Projects::HistoryController` and the measurement task all hold a filename and no row, and
      # answering :pointer for them would make every content-tracked source file's history
      # unreadable. `nodes.size` is nullable besides, so even the commit path can hand this nil --
      # and a row with no observed size must behave as it did before the ceiling existed, not raise.
      test "an unknown size falls back to the name rather than raising or demoting everything" do
        assert_equal :content, Maker::Git::Tracking.mode_for("notes.md")
        assert_equal :content, Maker::Git::Tracking.mode_for("notes.md", size: nil)
        assert_equal :pointer, Maker::Git::Tracking.mode_for("body.step", size: nil)
      end

      # THE TWO LIMITS MUST NOT DRIFT INTO CONTRADICTION. `MAX_CONTENT_BYTES` is argued partly FROM
      # `TextDiff::MAX_BYTES` -- content tracking above the diff cap buys availability and nothing
      # visible -- so a ceiling BELOW that cap would mean a file could be pointer-tracked while
      # still being perfectly diffable, which is the one combination neither constant's reasoning
      # allows. Deliberately an inequality and not a ratio: the two numbers answer different
      # questions and must be able to move independently.
      test "the content ceiling never falls below the diff cap" do
        assert_operator Maker::Git::Tracking::MAX_CONTENT_BYTES, :>=,
                        Maker::Git::TextDiff::MAX_BYTES
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
