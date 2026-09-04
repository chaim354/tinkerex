require "test_helper"

# Node.visible_entries — the display-filter scope FilesController#index and
# Maker::ProjectFolderListing both read. `.git`'s own marker rule and the dot-file toggle already
# have their own coverage (files_git_marker_test.rb); this is the `*.ptr` rule stage 3 (S3-1) adds
# beside them.
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
end
