require "test_helper"

module Library
  # The single source of truth for "names the library refuses to observe OR accept as a write
  # destination". Both halves of that sentence are load-bearing: the observers skip these so they
  # never become nodes, and the write guards reject them so nothing lands a live node at a path the
  # observers skip (the skip-list blind spot that wedged the library four times in phase 2b/4). The
  # observer tests (scanner_test / s3_observer_test) and the write-contract test both come back to
  # this predicate; this file pins the predicate itself.
  class OsClutterTest < ActiveSupport::TestCase
    test ".DS_Store is clutter at any depth" do
      assert OsClutter.ignore?(".DS_Store")
      assert OsClutter.ignore?("cad/.DS_Store")
      assert OsClutter.ignore?("a/b/c/.DS_Store")
    end

    test "AppleDouble resource forks (._*) are clutter at any depth" do
      assert OsClutter.ignore?("._foo")
      assert OsClutter.ignore?("._bracket.stl")
      assert OsClutter.ignore?("cad/._bracket.stl")
    end

    test "__MACOSX is clutter as a segment, so its whole subtree is refused" do
      assert OsClutter.ignore?("__MACOSX")
      assert OsClutter.ignore?("__MACOSX/junk.txt")
      assert OsClutter.ignore?("__MACOSX/nested/more.txt")
      assert OsClutter.ignore?("archive/__MACOSX/x")
    end

    test "the macOS volume-metadata names are clutter as a segment, at any depth" do
      %w[.Spotlight-V100 .Trashes .fseventsd .TemporaryItems .DocumentRevisions-V100 .apdisk]
        .each do |name|
        assert OsClutter.ignore?(name), name
        assert OsClutter.ignore?("#{name}/child"), "#{name}/child"
        assert OsClutter.ignore?("deep/#{name}/child"), "deep/#{name}/child"
      end
    end

    test "an ordinary CAD file is NOT clutter" do
      assert_not OsClutter.ignore?("bracket.stl")
      assert_not OsClutter.ignore?("cad/bracket.stl")
      # A real name that merely CONTAINS a clutter substring is not a clutter SEGMENT.
      assert_not OsClutter.ignore?("my.DS_Store.stl")
      assert_not OsClutter.ignore?("not__MACOSX.stl")
      assert_not OsClutter.ignore?("_single-underscore.stl")
      # A dot-file that isn't on the list is the user's own — we don't index-ban every hidden file.
      assert_not OsClutter.ignore?(".gitignore")
      assert_not OsClutter.ignore?(".keep")
    end
  end
end
