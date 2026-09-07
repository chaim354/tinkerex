require "test_helper"

# Node.visible_entries — the display-filter scope FilesController#index and
# Maker::ProjectFolderListing both read. `.git`'s own marker rule and the dot-file toggle already
# have their own coverage (files_git_marker_test.rb); this is the `*.ptr` rule stage 3 (S3-1) adds
# beside them, plus the build-output rule stage 4 (S4-2) adds beside the dot-dirs
# (Library::BuildOutput — a display rule, gated on show_hidden, never a scan skip).
class NodeTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "node-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
  end

  def file!(node_id, name)
    @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1)
  end

  # UNCONDITIONAL, UNLIKE A DOT-FILE — a `.ptr` stub is never something a user has a reason to look
  # for, so it stays out of `visible_entries` on BOTH arms (`show_hidden` true and false), where a
  # dot-file is offered back by the toggle. Still in the catalog either way (a display rule, never
  # a scan skip — §14b): rake projects:sweep_pointers is the write side that actually removes one.
  test "a *.ptr stub is excluded from visible_entries on both arms of show_hidden" do
    real = file!("n-real", "bracket.stl")
    ptr = file!("n-ptr", "bracket.stl.ptr")

    shown_by_default = @user.nodes.visible_entries(false)
    shown_with_hidden = @user.nodes.visible_entries(true)

    assert_includes shown_by_default, real
    assert_not_includes shown_by_default, ptr
    assert_includes shown_with_hidden, real
    assert_not_includes shown_with_hidden, ptr,
                        "a .ptr stub must stay hidden even with dot-files shown -- a different rule"
    assert Node.exists?(ptr.id), "hidden from every listing, still in the catalog"
  end

  # THE SUFFIX, NOT A FIXED BASENAME — a pointer sits beside its real file under THAT file's own
  # name plus `.ptr`, so the rule must match the trailing extension regardless of what precedes it.
  test "the exclusion is a suffix match, not a name containing .ptr anywhere else" do
    file!("n-mid", "printer.stl") # contains "ptr" mid-word; must not be caught
    ptr = file!("n-ptr", "model.stl.ptr")

    names = @user.nodes.visible_entries(false).pluck(:name)
    assert_includes names, "printer.stl"
    assert_not_includes names, "model.stl.ptr"
    refute_nil ptr
  end

  # THE NEGATIVE CASE, so the two tests above cannot be vacuously true over an empty scope: an
  # ordinary file with neither a dot-prefix nor a .ptr suffix is unaffected either way.
  test "an ordinary file is visible on both arms" do
    plain = file!("n-plain", "bracket.stl")

    assert_includes @user.nodes.visible_entries(false), plain
    assert_includes @user.nodes.visible_entries(true), plain
  end

  # STAGE 4, S4-2, STORY 4.8. `.pio` was hidden because it is dot-prefixed; `node_modules/` and
  # `__pycache__/` are the same clutter without the dot, and a firmware repo puts ~440 `.o/.d/.a`
  # files under one of them on the measured share library.
  #
  # A DISPLAY RULE, GATED ON `show_hidden` EXACTLY LIKE A DOT-DIR — not unconditional like `.git`
  # or `*.ptr`. There IS a reason to look inside a build directory (a linker map, a generated
  # header), and the "Show hidden" control is already the way back.
  test "a build-output directory is hidden by default and revealed with hidden files" do
    nm = @user.nodes.create!(node_id: "n-nm", name: "node_modules", kind: "dir", mtime: 1, size: 0)
    @user.nodes.create!(node_id: "n-pyc", name: "__pycache__", kind: "dir", mtime: 1, size: 0)

    hidden = @user.nodes.present.visible_entries(false).pluck(:node_id)
    assert_not_includes hidden, "n-nm"
    assert_not_includes hidden, "n-pyc"

    shown = @user.nodes.present.visible_entries(true).pluck(:node_id)
    assert_includes shown, nm.node_id
    assert_includes shown, "n-pyc"
    assert Node.exists?(nm.id), "hidden from a default listing, still in the catalog"
  end

  # `build/` IS DELIBERATELY NOT ON THE LIST, AND THIS IS THE ASSERTION THAT KEEPS IT OFF. A
  # lowercase `build/` is a folder a maker plausibly made themselves — assembly photos for a build
  # — it never appeared in the measured share library (the ~440 object files were under `.pio/`,
  # already a dot-dir), and the project page has no "Show hidden" control to get it back with. Two
  # names, not three; widening the list is a decision, which is what this test makes it.
  test "a directory named build is NOT build output and stays visible" do
    build = @user.nodes.create!(node_id: "n-build", name: "build", kind: "dir", mtime: 1, size: 0)
    assert_includes @user.nodes.present.visible_entries(false).pluck(:node_id), build.node_id
    assert_not_includes Library::BuildOutput::NAMES, "build"
  end

  # A FILE NAMED `node_modules` IS SOMEBODY'S FILE, NOT A DIRECTORY OF CLUTTER. The rule asks about
  # DIRECTORIES, unlike the dot-prefix rule, which asks about names of any kind. `nodes.kind` is
  # NOT NULL (db/schema.rb), so the SQL has no third answer.
  test "a FILE named node_modules is still visible" do
    file = @user.nodes.create!(node_id: "n-nmfile", name: "node_modules", kind: "file", mtime: 1, size: 4)
    assert_includes @user.nodes.present.visible_entries(false).pluck(:node_id), file.node_id
  end

  # THE HONEST LIMIT, PINNED SO IT IS NOT MISTAKEN FOR A BUG LATER: this hides the ENTRY, not its
  # descendants. A `main.o` under `node_modules/` is still a row and still appears in the flat
  # by-extension view — the identical, recorded limitation `.git` carries on chunk_remote. Closing
  # it needs a recursive CTE on a page in the hot path, which node.rb's own comment refuses.
  test "a file INSIDE a build-output directory is not hidden, and that is the recorded limit" do
    nm = @user.nodes.create!(node_id: "n-nm2", name: "node_modules", kind: "dir", mtime: 1, size: 0)
    obj = @user.nodes.create!(node_id: "n-obj", name: "main.o", kind: "file",
                              parent_node_id: nm.node_id, mtime: 1, size: 1)
    assert_includes @user.nodes.present.visible_entries(false).pluck(:node_id), obj.node_id
  end
end
