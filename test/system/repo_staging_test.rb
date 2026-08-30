require "application_system_test_case"
require "support/git_repo_fixture"

# The staging panel driven as a maker drives it: a real page, a real <details>, a real tick, a real
# Commit — and then git asked what actually landed.
#
# WHY THE BROWSER TIER IS NOT OPTIONAL HERE, and it is not the reason repo_editor_test gives. That
# one guards a write the server can also be asked to perform directly. This guards a FORM OVER A
# WORKING TREE THE MAKER IS ALSO USING: what may be committed is chosen entirely by which boxes are
# ticked, two of the three groups are collapsed and unchecked on arrival, and the only control that
# ticks more than one box at a time does not exist in the markup at all — commitgroup_controller.js
# builds it on connect. test/integration/web/repo_edit_flow_test.rb POSTs `paths:` arrays and proves
# `#create` commits the right things; it cannot say whether any of those arrays is reachable from
# the page. A `data-controller` name that resolves to nothing is a SILENT no-op — no error, no
# console warning (§14d, nine days) — so a Select all that ticks nothing would leave every
# assertion in that file green.
#
# THE ASSERTIONS THAT MATTER ARE AGAINST RUGGED, NOT AGAINST THE PAGE. The panel's own text is the
# thing under test, so believing it would be circular: "Committed 1 file(s)." is exactly what a box
# that quietly committed four would also say. The tree is what git will hand the maker back.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, on repo_editor_test.rb's precedent and for its reason: a commit
# box needs a REAL working tree, and a tmpdir plus one scan is the cheapest way to one.
# GitRepoFixture#library_root goes through `use_fresh_share_library!`, which owns its own teardown.
# This is NOT a backend-coverage test — the panel's absence where there is no local worktree is
# pinned by the integration suite.
class RepoStagingTest < ApplicationSystemTestCase
  include GitRepoFixture

  setup { @user = sign_in_as("repo-staging@example.com") }

  # `make_repo_with_every_state!` builds <library>/mixed. Opened fresh each time rather than
  # memoised: the point of every call is to read what a COMMIT just wrote.
  def mixed_repo = Rugged::Repository.new(File.join(library_root, "mixed"))

  def blob_at(tree, rel) = mixed_repo.lookup(tree.path(rel)[:oid]).content

  test "expanding Other changes, ticking one path and committing leaves every other path alone" do
    root = make_repo_with_every_state!

    visit repo_commit_path(root.node_id)

    # COLLAPSED ON ARRIVAL, AND THIS IS HALF THE SAFETY PROPERTY RATHER THAN A LAYOUT PREFERENCE.
    # The wider groups are unchecked (pinned at the request tier) AND out of the way, so committing
    # work done outside tinkerex takes a deliberate expand. Capybara reports content inside a closed
    # <details> as invisible, which is what makes this assertion possible at all.
    assert_no_selector "[data-group='other'] input[name='paths[]']"

    find("[data-group='other'] summary").click
    # NON-VACUITY: the group really is offering three committable rows, so "only one was committed"
    # below is a statement about a CHOICE and not about a list with one thing in it (§14e).
    assert_selector "[data-group='other'] input[name='paths[]']", count: 3

    find("[data-group='other'] [data-path='fresh.txt'] input[name='paths[]']").click
    fill_in "message", with: "just fresh, from the browser"
    click_on "Commit"

    assert_selector ".flash-notice", text: "Committed 1 file(s)."

    # THE TREE, NOT THE PAGE. Three unselected paths in three different states, each of which a
    # box that staged the working directory instead of HEAD would get wrong in its own way.
    tree = mixed_repo.head.target.tree
    assert_equal "just fresh, from the browser", mixed_repo.head.target.message
    assert_equal "new\n", blob_at(tree, "fresh.txt"), "the one ticked path must actually commit"
    assert_equal "before\n", blob_at(tree, "edited.txt"),
                 "edited.txt is modified on disk and was NOT ticked; the commit must keep HEAD's bytes"
    assert_equal "bye\n", blob_at(tree, "doomed.txt"),
                 "doomed.txt is deleted on disk and was NOT ticked; the commit must keep it"
    assert_raises(Rugged::TreeError) { tree.path(".DS_Store") }

    # AND THE WORKING TREE IS UNTOUCHED BY ALL OF IT — a commit records; it must not revert the
    # maker's uncommitted edits, which is the failure mode the diff panel's disabled merge controls
    # exist to avoid one layer up (diffview_controller).
    assert_equal "after\n", File.read(File.join(library_root, "mixed", "edited.txt"))

    assert_no_console_errors
  end

  # SELECT ALL IS PER-GROUP, AND THE WITNESS IS THE COMMIT. Asserting only that the clutter
  # checkboxes stayed unticked would be a DOM claim; making the control global also makes the
  # commit take `.DS_Store`, so this asserts on both tiers and the second one is the one that says
  # what a maker would actually be left with.
  test "Select all takes its own group and never another, so OS clutter stays out of the commit" do
    root = make_repo_with_every_state!

    visit repo_commit_path(root.node_id)
    find("[data-group='other'] summary").click
    # OPENED SO ITS STATE IS OBSERVABLE. A closed <details> is invisible to Capybara, so "none of
    # the clutter boxes is ticked" would be true of a group nobody could see either way — the
    # vacuous shape §15 warns about, and the exact assertion this test exists to make non-vacuous.
    find("[data-group='clutter'] summary").click
    assert_selector "[data-group='clutter'] input[name='paths[]']", count: 1

    # EACH GROUP CARRIES ITS OWN CONTROL, NAMING ITSELF. That the label says which group it acts on
    # is the invariant made legible on the page rather than only in the controller's header — and
    # it is what stops the two from reading as one control rendered twice.
    assert_selector "[data-group='other'] .commit-group-all", text: "Select all in Other changes"
    assert_selector "[data-group='clutter'] .commit-group-all", text: "Select all in OS clutter"

    within("[data-group='other']") { check "Select all in Other changes" }

    assert_equal 3, all("[data-group='other'] input[name='paths[]']").count(&:checked?)
    assert_equal 0, all("[data-group='clutter'] input[name='paths[]']").count(&:checked?),
                 "a global Select all is how a maker commits OS clutter by accident"

    fill_in "message", with: "everything I did outside tinkerex"
    click_on "Commit"
    assert_selector ".flash-notice", text: "Committed 3 file(s)."

    tree = mixed_repo.head.target.tree
    assert_equal "after\n", blob_at(tree, "edited.txt")
    assert_equal "new\n", blob_at(tree, "fresh.txt")
    assert_raises(Rugged::TreeError) { tree.path("doomed.txt") }
    # THE MUTATION'S REAL WITNESS: `.DS_Store` is still sitting in the working tree, still offered
    # in its own group, and must not be in this commit.
    assert_raises(Rugged::TreeError) { tree.path(".DS_Store") }
    assert_equal "same\n", blob_at(tree, "kept.txt"), "a path in no group at all is untouched"

    assert_no_console_errors
  end
end
