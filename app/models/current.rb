# REQUEST-SCOPED FLAGS. ActiveSupport::CurrentAttributes resets every attribute around each request
# and each job (the executor's run and complete hooks), so nothing set here outlives the request
# that set it. test/integration/web/library_unreachable_test.rb drives two requests in a row to
# hold that.
#
# `library_unreachable` IS RAISED IN ONE PLACE AND READ IN ONE. It is set where a
# FileLayer::FetchError was rescued into degraded output (Maker::Previews::ThumbnailMap.for), and
# read by the layout's banner (layouts/_library_unreachable). The banner never probes the store: a
# page that did not touch the port says nothing, so no request pays a round trip for the sentence.
# Do not "complete" it by asking the port from the layout. On chunk_remote that is the WAN in the
# metadata path (CLAUDE.md §2), paid on every page.
#
# WHAT RAISES IT TODAY, MEASURED: nothing in production. All three adapters answer `stat_all` from
# the local `nodes` table and never touch the store (FileLayer::Share#stat_all says so in as many
# words), so ThumbnailMap's rescue is reachable only through an adapter whose `stat_all` does read
# the store, or a stubbed port. A store outage still surfaces wherever bytes are read, as each
# controller's FetchError answer. A second setter belongs at a rescue that really reaches the store,
# and only for FetchError (several such rescues also swallow NotFound, which is not an outage).
class Current < ActiveSupport::CurrentAttributes
  attribute :library_unreachable
end
