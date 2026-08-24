# frozen_string_literal: true

# THE ONE PLACE THE MAKER LAYER ASKS FOR A COALESCED CHANGE BROADCAST, and the only host file
# outside the engine that names Sync::LibraryChannel.
#
# Maker::ProjectIntake wraps its moves in a batch so that filing N files emits ONE nudge instead of
# N (its own header measures why: on chunk each move is a Sync::Mutation.apply, and per-operation
# broadcasts are what LibraryChannel's contract exists to prevent). It called the channel directly
# and was on ArchitectureInvariantsTest's exception list for it.
#
# THREE ANSWERS, NOT TWO -- and the split is whether there is a CHANGELOG TO COALESCE AGAINST, not
# whether the engine happens to be loaded. Engine present (chunk) delegates to
# Sync::LibraryChannel.batch, unchanged. Engine ABSENT covers two different shapes that used to be
# one branch and now have to be two:
#
#   - share and s3 have NO changelog at all, so there is nothing to coalesce and no bookkeeping to
#     remove -- a bare `yield` is not a degraded version of batching, it is the SAME behaviour
#     (nothing ever broadcasts) with the bookkeeping removed. This is the argument this file
#     originally made for "without the engine" as a whole, and it is still exactly right for these
#     two backends -- what changed is that it is no longer the whole story.
#   - chunk_remote has no engine in-process (Arc A made that true) but DOES have a changelog, on
#     another machine, reached over HTTP. So the per-call cost this file exists to coalesce is real
#     there too: left alone, an eager Maker::ProjectIntake sweep pays one changelog PULL per
#     mutation on top of the mutation's own request -- two WAN round trips per file.
#     `FileLayer::ChunkRemote#batch` is that backend's own coalescing (see its comment for the
#     mechanism, which deliberately mirrors Sync::LibraryChannel.batch's thread-local shape), and
#     per THAT class's own comment this is the thing it predicted: "once the engine is remote...
#     coalescing becomes the remote adapter's concern."
#
# So there IS now something for a caller to branch on, where there used to be nothing -- but the
# branch lives HERE, not in ProjectIntake, which is the property worth keeping: it still calls one
# method and still does not learn which of the three answers it got.
#
# It exists so ProjectIntake does not have to know any of that. The exception list traded a
# 700-line service for this file, which is the whole of its own boundary.
module LibraryBroadcast
  # `chunk_remote` is checked BEFORE falling through to a bare `yield`, as its own line rather than
  # folded into `engine_wanted?` -- the two questions are independent (`engine_wanted?` asks
  # whether Sync:: is loaded; this asks whether FileLayer.current happens to be the one adapter
  # that has no engine but still has a changelog). A future backend answering yes to that gets its
  # own `is_a?` line beside this one, not a rename of it.
  def self.batch(user, &block)
    return Sync::LibraryChannel.batch(user, &block) if LibraryBackend.engine_wanted?
    return FileLayer.current.batch(user, &block) if FileLayer.current.is_a?(FileLayer::ChunkRemote)

    yield
  end
end
