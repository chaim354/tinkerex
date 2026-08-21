# frozen_string_literal: true

# One chunk of one version's manifest, mirrored from a remote sync server by
# FileLayer::ChunkRemote::ChangelogSync. See the migration for why it is keyed by version_id.
class RemoteManifestChunk < ApplicationRecord
  belongs_to :user

  scope :for_version, ->(version_id) { where(version_id:).order(:seq) }
end
