# THE LIVE-NODE INDEX FOR A PAGE OF LIBRARY NODES — one query over the UNION of every node id the
# page will render, read by every consumer on it. Sibling of AddonOrigins, which packages the same
# shape for the "Edit in <Addon>" link.
#
# WHY ONE INDEX. `Library::Reconciler` TOMBSTONES rather than destroys (deliberately — it is what
# makes a NAS reorganisation survivable), so an attachment row outlives the file it points at and
# every surface must decide whether to render it. Written per-surface it diverged exactly the way
# this repo's other guards have: `projects#show` filtered, `models#show` built an index and then
# consulted it for one derived list while `@by_role` and `@cover_att` read the unfiltered
# attachments — a dead attachment there painted a broken <img>, an <iframe> whose src 302s to the
# user's whole Files listing, and a hero cell polling a node /files/thumbnails will never report.
#
# LIVENESS IS `user.nodes.present`, NEVER THE PORT, and that is the constraint most likely to be
# "optimised away" by a reader who notices `ThumbnailMap` already stats the same ids. It rescues
# FileLayer::FetchError to {} so a backend blip degrades a THUMBNAIL rather than 503-ing a page of
# maker data that does not depend on the file backend — which means liveness derived from `stat_all`
# would make an unmounted NAS hide every attachment and tell the user they are gone. The maker layer
# is backend-neutral; `nodes` is the catalog all three backends populate. Pinned by
# test/integration/web/page_nodes_test.rb's FetchError test.
module PageNodes
  extend ActiveSupport::Concern

  private

  # { node_id => Node } for the LIVE nodes among `node_ids`; an absent key means tombstoned or
  # hard-gone, which is exactly the set that must not render. Callers PARTITION on it rather than
  # dereferencing with `&.`, so the views downstream can use plain `[...]` — a `&.name` that
  # silently renders an empty title is how a dead row keeps its tile.
  def live_nodes_for(node_ids)
    ids = node_ids.compact.uniq
    return {} if ids.empty?

    current_user.nodes.present.where(node_id: ids).index_by(&:node_id)
  end
end
