# THE SYNC SERVER'S ID FOR A DEVICE'S SIBLING (pentest H1b, tinkerex#465;
# docs/superpowers/plans/2026-10-22-device-token-lifecycle.md). On chunk_remote a device that signs in
# here is also handed a token for the sync server (FileLayer::ChunkRemote::SyncGrant), and nothing
# recorded which sync device that was. Revoking the maker device therefore had no way to name the
# sync sibling. Recorded from now on so that once tinkerex-sync has a revoke door, revoking here can
# reach it; rows enrolled before this column existed stay NULL and cannot be mapped. NULL on share
# and s3, which hand out no grant.
class AddSyncDeviceIdToDevices < ActiveRecord::Migration[8.1]
  def change
    add_column :devices, :sync_device_id, :bigint
  end
end
