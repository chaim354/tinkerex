require "test_helper"

# THE HANDLE (stage 3, S3-4): the first segment of every public URL, so it is normalized,
# format-checked, reserved-word-checked, unique -- and FROZEN while anything is published, which is
# the rule with the most to lose. Every link a maker has handed out is /u/<handle>/<slug>.
class UserHandleTest < ActiveSupport::TestCase
  def user!(**attrs) = User.create!(email: "handle-#{SecureRandom.hex(4)}@example.com", **attrs)

  # --- normalization -----------------------------------------------------------------------

  test "a handle is stripped and downcased" do
    user = user!(handle: "  Chaim ")
    assert_equal "chaim", user.handle
  end

  test "a blank handle normalizes to nil rather than failing the format check" do
    user = user!(handle: "")
    assert_nil user.handle
    assert_predicate user, :valid?
  end

  test "nil is a legitimate handle -- an account that never publishes never needs one" do
    assert_predicate user!, :valid?
  end

  # --- format ------------------------------------------------------------------------------

  test "accepts two characters, hyphens in the middle, and the full 32" do
    [ "a1", "desk-lamp-2", ("a" * 32) ].each do |good|
      user = User.new(email: "f-#{SecureRandom.hex(4)}@example.com", handle: good)
      assert_predicate user, :valid?, "expected #{good.inspect} (#{good.length}) to be accepted"
    end
  end

  test "refuses one character, 33, a leading or trailing hyphen, and an underscore" do
    # One character is refused DELIBERATELY: the message says 2-32 and the Account form's `pattern`
    # attribute says 2-32, so a regex accepting one would have the browser refuse what the server
    # allows. HANDLE_RE's middle group is not optional for exactly this reason.
    [ "a", ("a" * 33), "-abc", "abc-", "a_b", "a b", "Ünicode" ].each do |bad|
      user = User.new(email: "f-#{SecureRandom.hex(4)}@example.com", handle: bad)
      assert_not user.valid?, "expected #{bad.inspect} (#{bad.length}) to be refused"
      assert_includes user.errors[:handle].join(" "), "2–32 characters"
    end
  end

  # --- reserved ----------------------------------------------------------------------------

  test "every reserved handle is refused, by name" do
    # A loop, not a sample: the list exists to keep /u/<handle> from colliding with a top-level
    # path, and one uncovered entry is one live collision. Asserting the MESSAGE (not merely
    # invalidity) is what makes dropping `exclusion:` go red for the short entries too -- "u" and
    # "v1" would still fail the format check on length alone.
    assert_operator User::RESERVED_HANDLES.length, :>, 20, "the list went vacuous"
    User::RESERVED_HANDLES.each do |reserved|
      user = User.new(email: "r-#{SecureRandom.hex(4)}@example.com", handle: reserved)
      assert_not user.valid?, "expected #{reserved.inspect} to be reserved"
      assert_includes user.errors[:handle], "is reserved"
    end
  end

  # --- uniqueness --------------------------------------------------------------------------

  test "two accounts cannot hold the same handle" do
    user!(handle: "desk-lamp")
    second = User.new(email: "second-#{SecureRandom.hex(4)}@example.com", handle: "desk-lamp")
    assert_not second.valid?
    assert_includes second.errors[:handle], "has already been taken"
  end

  # --- the lock ----------------------------------------------------------------------------

  test "the handle is locked while a project is public" do
    user = user!(handle: "chaim")
    user.maker_projects.create!(name: "Desk Lamp", visibility: "public")

    assert_predicate user, :handle_locked?
    assert_not user.update(handle: "other")
    assert_includes user.errors[:handle].join(" "), "can't change"
  end

  test "the handle is locked while a project is unlisted" do
    user = user!(handle: "chaim")
    user.maker_projects.create!(name: "Desk Lamp", visibility: "unlisted")

    assert_not user.update(handle: "other")
    assert_includes user.errors[:handle].join(" "), "can't change"
  end

  test "a locked handle cannot be cleared either -- the published URL must not evaporate" do
    user = user!(handle: "chaim")
    user.maker_projects.create!(name: "Desk Lamp", visibility: "public")

    assert_not user.update(handle: "")
    assert_equal "chaim", user.reload.handle
  end

  test "with every project private the handle changes freely" do
    user = user!(handle: "chaim")
    user.maker_projects.create!(name: "Desk Lamp")

    assert_not_predicate user, :handle_locked?
    assert user.update(handle: "other"), user.errors.full_messages.to_sentence
    assert_equal "other", user.reload.handle
  end

  test "the FIRST claim is never blocked, even with a project already published" do
    # `handle_in_database.present?` is what makes this true. Unreachable through the UI today --
    # publishing needs a handle -- but the guard must not be the thing that makes it unreachable,
    # or a project published by any other route would lock its owner out of ever claiming one.
    user = user!
    user.maker_projects.create!(name: "Desk Lamp").update_column(:visibility, "public")

    assert user.update(handle: "chaim"), user.errors.full_messages.to_sentence
  end
end
