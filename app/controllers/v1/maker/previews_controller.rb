module V1
  module Maker
    # Thin CRUD + enqueue, scoped through current_user. The asset BYTES are served via the
    # ActiveStorage blob URL returned in the JSON (off Rails) — consistent with CLAUDE.md
    # §8/§15 ("keep bytes out of Rails").
    class PreviewsController < V1::BaseController
      def index
        previews = current_user.maker_previews
                     .for_node(params[:node_id])
                     .for_version(params[:version_id])
                     .of_kind(params[:kind])
                     .order(updated_at: :desc)
        render json: { previews: previews.map { |p| preview_json(p) } }
      end

      # Enqueue (or return the existing) preview for a node/kind. Idempotent: re-POSTing returns
      # the existing record.
      #
      # IDEMPOTENT PER (node, KIND) NOW, not per (node, version, kind) — there is one row per
      # (node, kind) and it is repointed as the content moves
      # (20260730001500_one_preview_per_node_and_kind.rb). `version_id` is therefore no longer a
      # thing a client CHOOSES; it records which content the stored asset was rendered from.
      #
      # THE LIFECYCLE IS `Maker::Previews::Enqueue`'S, NOT THIS CONTROLLER'S. It used to be inlined
      # here and had drifted to TWO of Enqueue's FOUR staleness axes: it checked `version_id` and
      # `failed`, and knew nothing of `renderer_revision` or `STALLED_AFTER`. Two consequences, both
      # silent: it wrote `version_id` while leaving `renderer_revision` at the column default of 1,
      # so a `.stl`/`.3mf`/`.lbrn2`/`.mage` row created through this door was born LYING (their
      # renderers declare 2, 2, 4 and 4) — the job then rendered with current code and marked it
      # `ready`, and every reader comparing revisions judged a correct current artifact stale and
      # re-enqueued it forever; and a renderer bump was invisible to the API entirely, since
      # `version_id` is all this door compared and a finished design's content never changes. It is
      # reachable in production: `client/sync-client`'s `enqueue_preview` (Tauri command
      # `maker_enqueue_preview`) POSTs here, and for an API-only desktop user nothing else repaired
      # the row.
      #
      # TEACHING THIS DOOR ABOUT `renderer_revision` WOULD FIX ONE AXIS OF FOUR and leave a fifth
      # copy of a rule that has already drifted three times (`8cbe740`, `b32b6e8`, `c3bc2f5` all
      # touched `enqueue.rb` only). Delegating is what makes the drift structurally impossible.
      #
      # OBSERVABLE WIRE CHANGE, AND IT IS THE CORRECT ONE: after a renderer bump this endpoint now
      # answers `ready` (the old artifact stays served while the rebuild runs) rather than a fresh
      # `pending`. That is CLAUDE.md §14h's "A CONTENT REPOINT BLANKS THE ARTIFACT; A RENDERER
      # REBUILD DOES NOT" arriving at the API, which never had it.
      #
      # `skip_unrenderable: false` IS THE ONE POLICY THAT STAYS THIS DOOR'S OWN — see
      # `Enqueue`'s own comment. An API client must get a pollable row for a name no renderer
      # handles, so it can observe the terminal `unsupported` the JOB writes. The row is left
      # `pending` and enqueued rather than written `unsupported` here, because only the job can
      # tell "no renderer for this type" from "renderer's toolchain missing on this box".
      def create
        attrs = preview_params
        return if refuse_stale_version!(attrs)

        node_id = attrs[:node_id]
        kind    = attrs.fetch(:kind, "thumbnail")
        # ASKED BEFORE THE CALL, because `Enqueue` finds-or-initializes and saves, so `new_record?`
        # is no longer observable afterwards — the 201/200 split is this endpoint's contract
        # (`previews_test.rb`, `catalog_isolation_test.rb`) and `previous_changes` would be a
        # fragile way to recover it.
        existed = current_user.maker_previews.exists?(node_id: node_id, kind: kind)

        preview = ::Maker::Previews::Enqueue.call(
          user: current_user, node_id: node_id, name: preview_name(attrs),
          version_id: attrs[:version_id], kind: kind, skip_unrenderable: false
        )

        render json: preview_json(preview), status: (existed ? :ok : :created)
      end

      private

      # THE NAME THE RENDERER IS CHOSEN BY, AND THE LADDER HAS THREE RUNGS FOR A REASON.
      #
      # `Enqueue` needs a NAME (it resolves a renderer and its revision from the extension), while
      # this endpoint's client may send only a `node_id` — which in this deployment is a UUID with
      # no extension. The node row is therefore consulted, exactly as `GeneratePreviewJob` does.
      #
      # DO NOT SHORTEN THIS TO `attrs[:filename] || attrs[:node_id]`. That passes a bare UUID as an
      # EXPLICIT filename, which then WINS over the job's own `node&.name` lookup — so every real
      # synced file would resolve to no renderer and be marked `unsupported`. Every `node_id` in
      # this suite happens to be name-shaped (`n1.svg`, `here.svg`, `ready.svg`), so the whole file
      # stays green over that mistake; `renderer_revision_test.rb` pins it with a UUID.
      def preview_name(attrs)
        attrs[:filename].presence ||
          current_user.nodes.find_by(node_id: attrs[:node_id])&.name ||
          attrs[:node_id]
      end

      # 422 rather than silently repointing the live row at content the library has moved past.
      #
      # With one row per (node, kind), honouring a request for an OLD version would throw away the
      # current render and replace it with a historical one — and on share/s3, where the library is
      # current-state only, the bytes it names do not exist at all, so the render would then fail
      # and leave the node with no preview. Refusing is the honest answer, and it names the version
      # the client should have asked for.
      #
      # ONLY WHEN WE CAN ACTUALLY TELL. The port is the only thing that knows the current token, so
      # a node the backend cannot resolve — never synced, already deleted, an unmounted share —
      # gives no basis to refuse anything, and the request falls through to the normal repoint. A
      # gate that guessed here would reject legitimate first-time renders for a node the API client
      # is about to create.
      def refuse_stale_version!(attrs)
        return false if attrs[:version_id].blank?

        current = FileLayer.current.stat(current_user, node_id: attrs[:node_id])&.content_token
        return false if current.blank? || current == attrs[:version_id]

        render json: { error: "stale_version", current_version_id: current },
               status: :unprocessable_entity
        true
      rescue FileLayer::NotFound, FileLayer::FetchError
        false
      end

      def preview_params
        params.require(:preview).permit(:node_id, :version_id, :kind, :filename)
      end

      def preview_json(p)
        {
          id: p.id, node_id: p.node_id, version_id: p.version_id, kind: p.kind,
          status: p.status, error: p.error, width: p.width, height: p.height,
          url: (p.asset.attached? ? url_for(p.asset) : nil),
          created_at: p.created_at, updated_at: p.updated_at
        }
      end
    end
  end
end
