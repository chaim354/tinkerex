# frozen_string_literal: true

require "test_helper"

# THE CASCADE, WHICH IS THE ONLY THING THIS MODEL NEEDED A TEST FOR.
#
# `remote_manifest_chunks` carries a real foreign key to `users`, so without a `dependent:` on the
# association `user.destroy` raises ActiveRecord::InvalidForeignKey the moment a chunk_remote
# deployment has mirrored anything. That was the state as shipped, and it was found by deleting a
# leftover test user by hand -- the rows had to be cleared first for the destroy to work at all.
#
# UNREACHABLE ON EVERY DEPLOYMENT RUNNING TODAY, and pinned anyway. The table only has rows in
# chunk_remote mode, which nothing is running yet; a guard written after the first real user hits it
# is a guard written after the bug.
class RemoteManifestChunkTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "manifest-#{SecureRandom.hex(4)}@example.com",
                         password: "correct horse battery staple", confirmed_at: Time.current)
  end

  def manifest_row(version_id: "v1", seq: 0)
    RemoteManifestChunk.create!(user_id: @user.id, version_id:, seq:,
                                chunk_hash: SecureRandom.hex(32), offset: 0, length: 5)
  end

  test "destroying a user takes its mirrored manifests with it" do
    3.times { |i| manifest_row(seq: i) }
    id = @user.id

    assert_nothing_raised { @user.destroy! }
    assert_equal 0, RemoteManifestChunk.where(user_id: id).count,
                 "manifest rows outlived their user -- the foreign key would have refused the delete"
  end

  test "it does not take another user's manifests" do
    other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                         password: "correct horse battery staple", confirmed_at: Time.current)
    RemoteManifestChunk.create!(user_id: other.id, version_id: "v1", seq: 0,
                                chunk_hash: SecureRandom.hex(32), offset: 0, length: 5)
    manifest_row

    @user.destroy!
    assert_equal 1, RemoteManifestChunk.where(user_id: other.id).count,
                 "a cascade scoped too widely is worse than none"
  end

  test "for_version returns one version's chunks in manifest order" do
    manifest_row(version_id: "v2", seq: 2)
    manifest_row(version_id: "v2", seq: 0)
    manifest_row(version_id: "v2", seq: 1)
    manifest_row(version_id: "other", seq: 0)

    rows = RemoteManifestChunk.where(user_id: @user.id).for_version("v2")
    assert_equal [ 0, 1, 2 ], rows.map(&:seq), "order matters: bytes are concatenated in it"
  end
end
