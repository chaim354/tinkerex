require "test_helper"

module Library
  # The one definition of `.git`, and the ONE ASYMMETRY that makes this design work: the marker
  # directory is observable and indexed, everything BENEATH it is neither observed nor writable.
  # Collapse the two and either the working-tree marker disappears (so Maker::AttachToProject's
  # :in_working_tree has nothing to detect) or the repo's objects come back into the catalog.
  #
  # TWO QUESTIONS, NOT ONE, and keeping them named is the point of this file. "At or beneath the
  # marker" (`marker_prefix(rel).present?` — may a write land here) and "STRICTLY beneath it"
  # (`internal?` — may an observer index this) have different answers on exactly one path, the
  # marker itself, and that path is the one the whole design turns on.
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

    # THE MARKER IS NOT INTERNAL TO ITSELF. This is the whole asymmetry in one assertion: the
    # observers must index `.git` and must not index anything under it, so a predicate that
    # answered true here would delete the marker the design exists to keep.
    test "internal? is STRICTLY BENEATH .git — the marker itself is not internal" do
      assert_not RepoMetadata.internal?(".git"), "the marker is observed, so it is not internal"
      assert_not RepoMetadata.internal?("firmware/.git")

      assert RepoMetadata.internal?(".git/config")
      assert RepoMetadata.internal?("firmware/.git/objects/ab/cdef")
      assert RepoMetadata.internal?("a/b/.git/HEAD")
    end

    # Whole segments, never prefixes — and `.github/` is the case that makes this more than
    # pedantry: it is a directory a real code library HAS, it starts with the marker's own name,
    # and a prefix match would take its whole subtree out of the catalog.
    test "a path merely NAMED like git metadata is not internal" do
      assert_not RepoMetadata.internal?(".gitignore")
      assert_not RepoMetadata.internal?("firmware/.gitmodules")
      assert_not RepoMetadata.internal?("notes/git/todo.txt")
      assert_not RepoMetadata.internal?(".github/workflows/ci.yml")
    end

    # A submodule's inner marker is still beneath the outer one, so the whole outer subtree is
    # internal — the same "outermost wins" fact marker_prefix states, from the other side.
    test "everything under the outermost marker is internal, nested repos included" do
      assert RepoMetadata.internal?("a/.git/modules/b/.git/HEAD")
    end

    test "non-strings answer false rather than raising" do
      assert_not RepoMetadata.marker?(nil)
      assert_nil RepoMetadata.marker_prefix(nil)
      assert_not RepoMetadata.internal?(nil)
    end
  end
end
