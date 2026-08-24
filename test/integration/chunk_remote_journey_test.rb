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
end
