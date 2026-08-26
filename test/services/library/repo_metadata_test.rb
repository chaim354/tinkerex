require "test_helper"

module Library
  # The one definition of `.git`, and the ONE ASYMMETRY that makes this design work: the marker
  # directory is observable and indexed, everything BENEATH it is neither observed nor writable.
  # Collapse the two and either the working-tree marker disappears (so Maker::AttachToProject's
  # :in_working_tree has nothing to detect) or the repo's objects come back into the catalog.
  #
  # Only the two predicates the observers call are pinned here. A third, `internal?` (STRICTLY
  # beneath a `.git` segment, so the marker itself answers false), is deliberately unwritten until
  # something calls it: an uncalled predicate is one nobody has driven.
  class RepoMetadataTest < ActiveSupport::TestCase
    test "the marker is the directory named .git, as a LEAF name" do
      assert RepoMetadata.marker?(".git")
      assert_not RepoMetadata.marker?(".gitignore")
      assert_not RepoMetadata.marker?("git")
      assert_not RepoMetadata.marker?("a/.git"), "marker? takes a leaf, never a path"
    end

    test "marker_prefix returns the path up to and including .git, or nil" do
      assert_nil RepoMetadata.marker_prefix("firmware/main.cpp")
      assert_equal ".git", RepoMetadata.marker_prefix(".git")
      assert_equal ".git", RepoMetadata.marker_prefix(".git/config")
      assert_equal "firmware/.git", RepoMetadata.marker_prefix("firmware/.git/objects/ab/cdef")
    end

    # Whole segments, never prefixes: `.gitignore` is an ordinary file and `notes/git/` is an
    # ordinary folder. The S3 observer drops every key marker_prefix answers for, so a prefix
    # match here would make a directory called `git` vanish from a bucket.
    test "a path merely NAMED like git metadata has no marker prefix" do
      assert_nil RepoMetadata.marker_prefix(".gitignore")
      assert_nil RepoMetadata.marker_prefix("firmware/.gitmodules")
      assert_nil RepoMetadata.marker_prefix("notes/git/todo.txt")
    end

    test "the OUTERMOST .git wins, so a repo inside a repo cannot hide one" do
      assert_equal "a/.git", RepoMetadata.marker_prefix("a/.git/modules/b/.git/HEAD")
    end

    test "non-strings answer false rather than raising" do
      assert_not RepoMetadata.marker?(nil)
      assert_nil RepoMetadata.marker_prefix(nil)
    end
  end
end
