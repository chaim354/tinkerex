require "test_helper"
require "support/git_repo_fixture"

module Web
  # The trash page and the two repository pages after PR 4 (spec §8): page heads with button
  # actions, the trash table carrying the same column classes as the Files list (so the phone rules
  # apply), Restore and Commit as buttons, and history rows with the mono oid in its own cell.
  # Everything the repo tests pin — the form, the hidden head, the group/path/state attributes —
  # is untouched; this file asserts the chrome around them.
  class RepoTrashPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the trash page has a head with a ghost Back, column classes, and Restore as a button" do
      @root = use_fresh_share_library!
      node = create_node!(@user, node_id: SecureRandom.uuid, name: "old-bracket.stl", kind: "file")
      delete file_path(node.node_id)
      get trash_index_path
      assert_response :success
      assert_select ".page-head h1", text: "Trash"
      assert_select ".page-head a.btn.ghost[href=?]", files_path, text: "← Back to Files"
      assert_select "table.files th.col-name", text: "Name"
      assert_select "table.files td.col-name", text: "old-bracket.stl"
      assert_select "table.files td.num.col-size"
      assert_select "table.files td.col-modified"
      assert_select "table.files td.row-actions.col-actions form[action=?] button.btn.small", restore_trash_path(node.node_id), text: "Restore"
    end

    test "an empty trash keeps its sentence in the empty component" do
      get trash_index_path
      # `.muted` DROPPED (UI-cohesion spec §2.4): `.empty` already sets `color: var(--fg-muted)`,
      # so the modifier was inert on all 16 sites that carried it. The sentence and the component
      # are what this test is about, and both survive.
      assert_select "p.empty", text: "Trash is empty."
    end

    include GitRepoFixture

    test "the commit page has a head with actions and Commit as the primary submit" do
      @library = use_fresh_share_library!
      root = make_repo!(name: "demo", files: { "notes.md" => "hello\n" })
      File.write(File.join(library_root, "demo", "notes.md"), "hello world\n")   # a change outside tinkerex: the "other" group
      get repo_commit_path(root.node_id)
      assert_response :success
      assert_select ".page-head h1", text: /Commit — demo/
      assert_select ".page-head .page-actions a.btn.ghost[href=?]", files_path(folder: root.node_id), text: "Browse files"
      assert_select ".page-head .page-actions a.btn.ghost[href=?]", repo_history_path(root.node_id), text: "History"
      assert_select "form.commit-box section.commit-group.panel[data-group='other']"
      assert_select "form.commit-box .editor-bar input[type='submit'][value='Commit'].primary"
    end

    test "the history page has a head with actions and mono oids" do
      @library = use_fresh_share_library!
      root = make_repo!(name: "demo", files: { "notes.md" => "hello\n" })
      get repo_history_path(root.node_id)
      assert_response :success
      assert_select ".page-head h1", text: /History — demo/
      assert_select ".page-head .page-actions a.btn.ghost", text: "Browse files"
      assert_select ".page-head .page-actions a.btn.ghost", text: "Review and commit"
      assert_select "ol.commit-history li.commit-history-row[data-oid] code.mono.commit-oid"
      assert_select "ol.commit-history li.commit-history-row .commit-subject", text: "seed"
    end
  end
end
