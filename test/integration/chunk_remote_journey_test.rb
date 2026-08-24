# frozen_string_literal: true

require "test_helper"
require_relative "../support/chunk_remote_journey"

# DRIVES THE MAKER APP AGAINST A REAL STANDALONE SYNC SERVER. Every node here is created through a
# real door -- never `user.nodes.create!` -- because a hand-built row exists only in the local
# mirror and the server has never heard of it, so a write verb against one would 404 for a reason
# that says nothing about chunk_remote.
#
# THIS SUITE IS ARC A'S INSTRUMENT, NOT ARC A'S PRODUCT -- but be precise about which tests that
# covers. An earlier version of this comment claimed the whole class was "expected to be red when
# it lands," and that was already wrong once: these three tests came back GREEN on the FIRST run
# against a real standalone server, not asserted on faith -- verified against that server's own
# log as genuine wire traffic (a presigned chunk PUT, `finalize` inserting a real
# `Version`/`Node`/`ChangelogEntry` row apiece, and the `/v1/changes` pull that refreshes the local
# mirror's `nodes` table). The failures Arc B works from are the three tests Task 5 adds -- each
# names its own expected failure individually, rather than this docstring claiming one on the
# whole file's behalf. It is deliberately NOT a bin/ci gate -- test/ci_hygiene_test.rb asserts set
# equality between `bin/ci --list-ci` and ci.yml's gate jobs, so a red gate is a red main.
# .github/workflows/sync-contract.yml carries the signal.
class ChunkRemoteJourneyTest < ActionDispatch::IntegrationTest
  include ChunkRemoteJourney

  setup { skip_unless_remote_server }

  # THE MUTATION-CHECK ON THE SKIP ITSELF. §14j: a guard that skips on the thing it asserts is
  # vacuous, and it reported SUCCESS while asserting nothing. Break `skip_unless_remote_server` to
  # always skip and this test is the one that notices.
  test "the journey suite does not skip when a server is configured" do
    assert ChunkRemoteJourney.configured?,
           "setup should have skipped this test if no server were configured"
    assert_equal "chunk_remote", ENV["LIBRARY_BACKEND"]
    assert_kind_of FileLayer::ChunkRemote, FileLayer.current
  end

  test "an upload round-trips byte-for-byte through the sync server" do
    sign_in
    # CONTENT varies, not just the filename. Chunks are content-addressed, so a repeat of fixed
    # bytes dedupes to an empty put_urls and the Net::HTTP upload path silently never runs --
    # see upload_through_ui's own comment. The suite would stay green while proving nothing.
    bytes = "solid #{journey_prefix}\nendsolid\n".b
    node_id = upload_through_ui("#{journey_prefix}-bracket.stl", bytes)

    get blob_file_path(node_id)
    assert_response :success
    assert_equal bytes, response.body,
                 "the bytes that came back are not the bytes that went in"
  end

  test "an uploaded file appears on the files page" do
    user = sign_in
    name = "#{journey_prefix}-listed.stl"
    upload_through_ui(name, "listed #{journey_prefix}".b)

    get files_path
    assert_response :success
    assert_includes response.body, name

    assert user.nodes.present.exists?(name:),
           "the local mirror should hold the node after finalize_upload refreshed it"
  end

  test "a folder can be created, and a file moved into it" do
    user = sign_in
    folder = "#{journey_prefix}-folder"
    node_id = upload_through_ui("#{journey_prefix}-moved.stl", "moved #{journey_prefix}".b)

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success, "create_folder failed: #{response.body}"
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    # THROUGH Maker::MoveNode, NOT a controller: verified against `bin/rails routes` -- FilesController
    # exposes GET/DELETE on /files/:id and no update action at all, so there is no PATCH door to
    # drive. MoveNode is the named service §14d says every web move goes through, which makes it the
    # real door here rather than a shortcut past one.
    Maker::MoveNode.call(user, node: user.nodes.present.find_by!(node_id:),
                         new_parent_node_id: folder_node.node_id)

    assert_equal folder_node.node_id, user.nodes.present.find_by!(node_id:).parent_node_id,
                 "the move did not reach the mirror -- refresh! after move is what puts it there"
  end

  test "a file can be deleted, listed in trash, and restored" do
    user = sign_in
    name = "#{journey_prefix}-doomed.stl"
    node_id = upload_through_ui(name, "doomed #{journey_prefix}".b)

    # `assert_response :redirect` WOULD NOT DISCRIMINATE HERE, and that is the same defect the
    # journey harness's own sign_in had. FilesController redirects to files_path on SUCCESS
    # (files_controller.rb:628, with a notice) and its three rescue_from arms redirect to
    # files_path on EVERY html failure (:106 NotFound, :124 FetchError, :134
    # UnsupportedOperation), each with an ALERT. Same status, same Location -- the flash is the
    # only thing that differs, so it is what gets asserted.
    delete file_path(node_id)
    assert_redirected_to files_path
    assert_nil flash[:alert], "delete was refused: #{flash[:alert]}"
    assert_not user.nodes.present.exists?(node_id:), "delete did not tombstone the mirror row"

    get trash_index_path
    assert_response :success
    assert_includes response.body, name

    post restore_trash_path(node_id)
    # TrashController's failure arms redirect to trash_index_path with an alert (:40, :46) while
    # success goes to files_path with a notice (:79), so the destination alone would discriminate
    # here -- the alert check is kept anyway so every redirect in this file reads the same way.
    assert_redirected_to files_path
    assert_nil flash[:alert], "restore was refused: #{flash[:alert]}"
    assert user.nodes.present.exists?(node_id:), "restore did not revive the mirror row"
  end

  test "a directory delete cascades, because dir_deletable is true on chunk_remote" do
    user = sign_in
    folder = "#{journey_prefix}-cascade"

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    child = upload_through_ui("#{journey_prefix}-child.stl", "child #{journey_prefix}".b,
                              parent_node_id: folder_node.node_id)

    delete file_path(folder_node.node_id)
    assert_redirected_to files_path
    assert_nil flash[:alert], "the directory delete was refused: #{flash[:alert]}"

    assert_not user.nodes.present.exists?(node_id: child),
               "SubtreeDelete must cascade to descendants -- an orphaned child is §14a's " \
               "recorded trap, and dir_deletable is true precisely because the server cascades"
  end
end
