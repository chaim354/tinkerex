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
      # THE LIFECYCLE IS `Maker::Previews::Enqueue`'S, NOT THIS CONTROLLER'S. It was inlined here
      # and had drifted to TWO of Enqueue's FOUR staleness axes, writing `version_id` while leaving
      # `renderer_revision` at the column default — so a `.stl`/`.3mf`/`.lbrn2`/`.mage` row born
      # through this door was stale by construction and re-enqueued forever. Teaching it one axis
      # would leave a fifth copy of a rule that has already drifted; delegating makes the drift
      # structurally impossible. (Arc, SHAs and reachability: the commit message and STATUS.md.)
      #
      # OBSERVABLE WIRE CHANGE, AND IT IS THE CORRECT ONE: after a renderer bump this endpoint now
      # answers `ready` (the old artifact stays served while the rebuild runs) rather than a fresh
      # `pending`. That is CLAUDE.md §14h's "A CONTENT REPOINT BLANKS THE ARTIFACT; A RENDERER
      # REBUILD DOES NOT" arriving at the API, which never had it. The row itself reads
      # `rebuilding` since F-S08-2; `preview_json` below keeps this wire's `ready`, and says why.
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

      # `ready` AND `url` MOVE TOGETHER, AND BOTH ARE `servable?` (F-S08-2). tinkerex-client's
      # `Preview` documents "`url` is null until `status == "ready"`", and this wire kept neither half:
      #   - a picture mid-rebuild is `ready`, an older build's picture of this same content, which is
      #     what `ready` promised before the status was split (the rebuild note on #create) — while a
      #     MEASURED kind mid-rebuild is not: its older payload is wrong, so it reads `pending`, the
      #     web Measure poll's answer for the same row. `rebuilding` itself never reaches this wire;
      #     exposing a new value is a change to make deliberately, with the client.
      #   - `url` was emitted for ANY attached asset, so a row repointed at new content (`pending`) or
      #     one whose render failed handed out an OLDER asset beside a status saying it was not ready.
      #     No client reads a url off a row that is not ready: tinkerex-client asserts it only on a
      #     ready one.
      def preview_json(p)
        {
          id: p.id, node_id: p.node_id, version_id: p.version_id, kind: p.kind,
          status: p.wire_status, error: p.error, width: p.width, height: p.height,
          url: (url_for(p.asset) if p.servable?),
          created_at: p.created_at, updated_at: p.updated_at
        }
      end
    end
  end
end
