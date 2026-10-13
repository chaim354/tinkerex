module Maker
  module Previews
    # Resolve the CURRENT-version, CURRENT-BUILD thumbnail for a set of file-library node_ids, and
    # enqueue the ones that are missing. Degrade-safe.
    #
    # A thumbnail is current for a node when it matches BOTH the node's content token (from the
    # FileLayer port) and the deployed renderer's revision. That pair has ONE definition,
    # `Enqueue.current_preview?`, shared with `FilesController`'s two single-node doors.
    # If the backend is unreachable (FetchError), we return an empty map so callers show a spinner
    # /icon rather than 503-ing a page of maker data that does not depend on the file backend.
    # That rescue also raises `Current.library_unreachable`, which the layout's banner reads. It
    # cannot fire in production today: `stat_all` is catalog-only on all three adapters
    # (app/models/current.rb lists the setters that can).
    #
    # THIS IS THE ONE IMPLEMENTATION, and `FilesController` calls it rather than keeping its own.
    # It held the only copy of both rules below, which is how the Models page, the project covers
    # and the attachment tiles came to have neither: they go through this class, and this class
    # only READ. That is this repo's dominant failure shape — a guard that exists at one door and
    # silently does not at the next (§14b's reserved names, §14c's chunk name check, §14d's five
    # `port_writable?` copies) — so the fix is one implementation, not a second copy of each rule.
    #
    # WHY THE ENQUEUE LIVES HERE AND NOT IN THE CONTROLLERS (§14d: a verb more than one controller
    # performs gets a named service). Five call sites across two controllers need it, two of them
    # in `ProjectsController#show` alone. More decisively, the backfill's inputs are exactly what
    # this class computes and does not expose: the port's per-node `FileInfo` (name, kind, token)
    # and the set of rows that count as *current*, which `previews_for` below resolves. A
    # controller-side backfill would have to re-derive both — a second `stat_all` per page, plus a
    # second spelling of "which rows already exist" — which is the duplication being removed. And a
    # sixth caller gets it without knowing it needed to ask.
    #
    # A page render therefore WRITES: it creates preview rows and enqueues jobs on a GET. That is
    # already true of `files#index` and it is bounded (BACKFILL_LIMIT), idempotent (`Enqueue`
    # no-ops on a current row) and best-effort. The alternative — an adjacent `backfill` call each
    # caller must remember — is the two-call shape `FilesController` had, and forgetting it is
    # precisely how these five call sites diverged in the first place.
    class ThumbnailMap
      # How many missing thumbnails ONE page render may enqueue. Same budget, same argument as
      # `FilesController::BACKFILL_LIMIT`, which this replaces: it bounds a page whose row count is
      # not user-shaped (a library indexed before previews shipped has files and no rows), and it
      # is a budget rather than a correctness limit because the rows this pass creates are exactly
      # what makes the next visit skip them. Measured there at 2500 files: uncapped, one request
      # inserted 2000 rows and enqueued 2000 jobs.
      BACKFILL_LIMIT = 100

      # The five maker-page callers hold node ids and nothing else, so the port call is made here.
      # THE BACKFILL IS UNCONDITIONAL AT THIS DOOR: every caller of it is a page render, and a page
      # render is exactly the surface whose spinner has to resolve. A caller that must not write
      # holds the port's answer already and comes in through `from_info`.
      def self.for(user, node_ids)
        ids = node_ids.compact.uniq
        info =
          if ids.empty?
            {}
          else
            begin
              FileLayer.current.stat_all(user, node_ids: ids)
            rescue FileLayer::FetchError
              Current.library_unreachable = true
              {}
            end
          end
        from_info(user, ids, info, backfill: true)
      end

      # The same resolution for a caller that ALREADY HOLDS the port's answer — `FilesController`
      # stats the page once and passes `@info_by_node` in. Asking the port again here would be a
      # second `stat_all` per request: on share that is a filesystem stat per node, doubled.
      #
      # `backfill:` IS REQUIRED, NOT DEFAULTED, because this door's two callers disagree and the
      # wrong answer is silent either way. `#index` must self-heal; `#thumbnails` must not — it is
      # polled every 2 seconds for up to 40 tries, so enqueueing there would be a per-node write on
      # every tick for work the page render that produced those spinners has already done.
      #
      # `node_ids` is walked IN ORDER, so the budget is spent on what the user is most likely
      # looking at first — the port's answer is a Hash in database order, which is not that.
      def self.from_info(user, node_ids, info, backfill:)
        map = new(previews: previews_for(user, info))
        backfill!(user, node_ids, info, map) if backfill
        map
      end

      # The rows for these nodes' current content AND current renderer build, in ONE query.
      #
      # A ROW FROM AN OLDER RENDERER IS NOT "EXISTING". Leaving that out is what made the whole
      # `renderer_revision` mechanism unreachable for thumbnails once already: `Enqueue` compares
      # revisions correctly, but only something that CALLS it can act on that, and the backfill
      # below skips any node this method reports a row for. So a stale row satisfied the check,
      # nothing re-enqueued, and 172 of 174 LightBurn thumbnails sat at revision 1 through two
      # deploys that had bumped it (§14h). On this path the second half of the same bug also
      # showed: the stale artifact was served, so the page presented an old picture as the file's
      # current thumbnail — every STL/3MF still framed by the pre-Z-up camera, for instance.
      #
      # FILTERED IN RUBY, NOT SQL, because the current revision depends on the RENDERER and so on
      # each node's filename — there is no single value to put in a WHERE. Still one query, which
      # is what page_query_budget_test.rb asserts (constancy in N, never a literal); this only
      # drops rows from its result. BOTH staleness axes are asked of `Enqueue`, which owns them,
      # rather than half-restated here — this method used to compare the token in SQL and the
      # revision in Ruby, which is how it came to be the third copy of a two-part rule.
      #
      # KEYED ON `node_id` ALONE, which is COMPLETE and not a shortcut: since
      # 20260730001500_one_preview_per_node_and_kind.rb there is one row per (user, node, kind),
      # enforced by the unique index `idx_maker_previews_unique`, and this query fixes the user
      # and the kind. The old `(node_id, version_id)` composite key was left over from the
      # per-version table that migration replaced — a vestige rather than a safeguard: it made the
      # `version_id: live` IN-clause fetch rows across ALL live tokens and then silently discard
      # every one whose token was not that node's own, which is work done twice to reach the same
      # answer.
      def self.previews_for(user, info)
        user.maker_previews
            .where(kind: "thumbnail", node_id: info.keys)
            .select do |p|
              fi = info[p.node_id]
              Maker::Previews::Enqueue.current_preview?(p, name: fi&.name,
                                                           version_id: fi&.content_token)
            end
            .index_by(&:node_id)
      end

      # LAZY BACKFILL. The eager seams (upload/commit/scan) only cover files that arrive AFTER a
      # feature ships; a library indexed before it has files but no rows, and a bumped renderer
      # leaves rows that are worse than none. Without this, such a cell shows a spinner that
      # NOTHING will ever resolve: `files/_thumb.html.erb` spins on a nil row, `thumbs_controller`
      # polls `/files/thumbnails`, which omits a node with no row from its JSON entirely, so the
      # client's `if (!entry) continue` runs 40 times and gives up — still spinning.
      #
      # Renderable files only: a name no renderer handles gets no row (never litter the table with
      # rows that can only ever be `unsupported`) and renders as a static icon, not a spinner.
      # Directories are asked of the PORT's `kind`, which all three adapters carry — a folder named
      # `models.stl` is still a folder, and there are no bytes to render.
      #
      # The new rows are deliberately NOT merged into the map: the view then sees nil and shows a
      # spinner, which is now truthful because a job IS coming.
      def self.backfill!(user, node_ids, info, map)
        budget = BACKFILL_LIMIT
        node_ids.each do |node_id|
          break if budget.zero?

          fi = info[node_id]
          next if fi.nil? || fi.kind != "file"
          next if fi.content_token.nil? || map.current?(node_id)
          next if Maker::Previews::Registry.for_filename(fi.name).nil?

          Maker::Previews::Enqueue.call(user:, node_id:, name: fi.name, version_id: fi.content_token)
          budget -= 1
        end
      end
      private_class_method :previews_for, :backfill!

      def initialize(previews:)
        @previews = previews
      end

      # The Maker::Preview for a node's current content and current build, or nil (nil => spinner
      # in _thumb). Every row in `@previews` has already passed `Enqueue.current_preview?`, so
      # there is nothing left to compare here — a node with no CURRENT row is simply absent.
      def thumb(node_id) = @previews[node_id]

      # Is there already an artifact for this node's current content and current build? Distinct
      # from `thumb(...)` being non-nil only in intent — this is the backfill's question, and
      # naming it keeps the loop from reading as though it cared about the row itself.
      def current?(node_id) = !thumb(node_id).nil?
    end
  end
end
