# frozen_string_literal: true

# THE LOCAL MANIFEST MIRROR for chunk_remote: which chunks, in what order, make up a version.
#
# WHY THIS HAS TO EXIST AT ALL. `POST /v1/chunks/download` turns chunk HASHES into presigned URLs --
# it cannot be asked "what are the chunks for node X". Manifests arrive unbidden in /v1/changes and
# /v1/tree payloads, so a sync client's job is to keep them; the Rust fs-provider does exactly this
# with its own manifest_chunks table. The alternative -- a new per-node manifest endpoint -- would
# break the design's "zero new sync-server endpoints", which is the claim that makes Stage 4 cheap.
#
# KEYED BY version_id, NOT manifest_id, AND THAT IS A DELIBERATE DENORMALISATION. The server keys by
# manifest_id so identical content shares one manifest; here the lookup always starts from a
# content_token, which IS a version_id (FileInfo#content_token, and what maker_previews stores).
# Going through manifest_id would mean a second column on `nodes` and a join, to save rows for a
# duplication that only occurs when two versions have byte-identical content. Reading is the hot
# path; storage is not.
#
# It also means an OLD version's manifest survives, which is what lets
# `read(content_token: <older>)` work -- a contract requirement, not a nicety.
class CreateRemoteManifestChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :remote_manifest_chunks do |t|
      t.integer :user_id, null: false
      t.string  :version_id, null: false
      t.integer :seq, null: false
      t.string  :chunk_hash, null: false
      t.bigint  :offset, null: false
      t.bigint  :length, null: false
      t.timestamps
    end

    # The only read this table has: every chunk of one version, in order.
    add_index :remote_manifest_chunks, %i[user_id version_id seq], unique: true,
              name: "index_remote_manifest_chunks_on_version_and_seq"
    add_foreign_key :remote_manifest_chunks, :users
  end
end
