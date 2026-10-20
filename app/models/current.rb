# REQUEST-SCOPED FLAGS. ActiveSupport::CurrentAttributes resets every attribute around each request
# and each job (the executor's run and complete hooks), so nothing set here outlives the request
# that set it. test/integration/web/library_unreachable_test.rb drives two requests in a row to
# hold that.
#
# `library_unreachable` IS RAISED WHERE A FileLayer::FetchError IS RESCUED INTO DEGRADED OUTPUT
# DURING A RENDER, and read in one place, the layout's banner (layouts/_library_unreachable). The
# setters that CAN fire, because each one really reads the store:
#
#   Maker::Readme.for                   the project page's README card, and a repository's README
#   Maker::RepoCard.git_facts           a repository card's history facts
#   Maker::GerberSets.job_layer_names   a .gbrjob's file page
#   Maker::GerberArchive.for            a Gerber zip's file page
#   Maker::ThreeMfManifest.for          a 3MF's file and model pages
#
# THE LAST TWO CACHE WHAT THEY READ, so each rescues OUTSIDE its `Rails.cache.fetch`: a rescue
# inside the block returns its nil INTO the cache, and an outage then reads as "not a board" or "no
# manifest" for the cache's whole lifetime. A setter that caches keeps the failure out of it.
#
# AND ONE THAT CANNOT, TODAY: Maker::Previews::ThumbnailMap.for. `stat_all` is catalog-only on all
# three adapters (it answers from the local `nodes` table and never touches the store;
# FileLayer::Share#stat_all says so in as many words), so that rescue is reached only through a
# stubbed port. It stays for an adapter whose `stat_all` does read the store.
#
# EACH SETTER RESCUES FetchError IN AN ARM OF ITS OWN, and the NotFound beside it raises nothing: a
# file that is gone is not an outage, and saying the library cannot be reached about it would be
# false. A new setter keeps that split.
#
# The banner never probes the store: a page that did not touch the port says nothing, so no request
# pays a round trip for the sentence. Do not "complete" it by asking the port from the layout. On
# chunk_remote that is the WAN in the metadata path (CLAUDE.md §2), paid on every page.
class Current < ActiveSupport::CurrentAttributes
  attribute :library_unreachable
end
