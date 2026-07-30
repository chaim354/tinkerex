require "test_helper"

module Maker
  # The folder map, and above all its TOTALITY.
  class ProjectFoldersTest < ActiveSupport::TestCase
    # THE GUARD THIS FILE EXISTS FOR. `folder_for` uses `fetch` with no default: reached with an
    # unmapped role, it raises KeyError — LOUD, not silent. What makes this test necessary is that
    # the raise is normally UNREACHABLE: role_for only returns a role once some extension is wired
    # to it in ROLE_BY_EXT, so a role added to ROLES without a folder decision can sit here
    # completely unexercised, with nothing to notice, until a real file of that new type is
    # finally scanned and the raise becomes a production incident. This test is what catches the
    # gap first. (The rejected `fetch(role, "other")` default is the genuinely silent failure — it
    # would misfile instead of raising.) Mutation-check it by deleting a key from ROLE_FOLDERS.
    test "every role has a folder" do
      assert_equal Maker::FileAttachment::ROLES.to_set,
                   Maker::ProjectFolders::ROLE_FOLDERS.keys.to_set,
                   "add the new role to ROLE_FOLDERS — a role with no folder is never filed"
    end

    test "the categories the folders were named for" do
      assert_equal "cnc",      Maker::ProjectFolders.folder_for("pocket.nc")
      assert_equal "cnc",      Maker::ProjectFolders.folder_for("roughing.gcode")
      assert_equal "laser",    Maker::ProjectFolders.folder_for("box.lbrn2")
      assert_equal "design",   Maker::ProjectFolders.folder_for("panel.svg")
      assert_equal "design",   Maker::ProjectFolders.folder_for("panel.dxf")
      assert_equal "models",   Maker::ProjectFolders.folder_for("bracket.stl")
      assert_equal "cad",      Maker::ProjectFolders.folder_for("body.f3d")
      assert_equal "docs",     Maker::ProjectFolders.folder_for("guide.pdf")
      assert_equal "docs",     Maker::ProjectFolders.folder_for("notes.md")
      assert_equal "images",   Maker::ProjectFolders.folder_for("photo.jpg")
      assert_equal "archives", Maker::ProjectFolders.folder_for("printables.zip")
    end

    # An unrecognised extension must land somewhere rather than raise: role_for defaults to
    # "other", so this is really asserting the two defaults agree.
    test "an unknown extension goes to other" do
      assert_equal "other", Maker::ProjectFolders.folder_for("mystery.qqq")
      assert_equal "other", Maker::ProjectFolders.folder_for("README")
    end

    # The names are lowercase because they appear in Finder and on the NAS — deliberately NOT
    # ROLE_LABELS ("G-code", "CAD source"), which are UI headings.
    test "folder names are single lowercase path segments" do
      Maker::ProjectFolders::ROLE_FOLDERS.values.uniq.each do |name|
        assert_match(/\A[a-z0-9]+\z/, name, name)
      end
    end
  end
end
