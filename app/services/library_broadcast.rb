# frozen_string_literal: true

# THE ONE PLACE THE MAKER LAYER ASKS FOR A COALESCED CHANGE BROADCAST, and the only host file
# outside the engine that names Sync::LibraryChannel.
#
# Maker::ProjectIntake wraps its moves in a batch so that filing N files emits ONE nudge instead of
# N (its own header measures why: on chunk each move is a Sync::Mutation.apply, and per-operation
# broadcasts are what LibraryChannel's contract exists to prevent). It called the channel directly
# and was on ArchitectureInvariantsTest's exception list for it.
#
# WITHOUT THE ENGINE THE HONEST ANSWER IS `yield`, NOT A RAISE AND NOT A SILENT DROP. share and s3
# have no changelog, so no seq is ever recorded and the real `batch` would broadcast nothing at its
# ensure block anyway -- the no-engine path is not a degraded version of the behaviour, it is the
# same behaviour with the bookkeeping removed. That is why this is a seam rather than a capability:
# there is nothing for a caller to branch on.
#
# It exists so ProjectIntake does not have to know any of that. The exception list traded a
# 700-line service for this file, which is the whole of its own boundary.
module LibraryBroadcast
  def self.batch(user, &block)
    return yield unless LibraryBackend.engine_wanted?

    Sync::LibraryChannel.batch(user, &block)
  end
end
