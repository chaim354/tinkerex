module Files
  # THE LIBRARY'S 3D MODELS VIEW (structural redesign §5.4, slice 5) — the old /models index, moved
  # verbatim from ModelsController#index (which now 301s here; its history stays in
  # models_controller.rb). Every catalogued model as a cover tile; a tile links to model_path, which
  # lands on the model's folder whenever that folder shows its strip (Maker::ModelFolder) — decided at
  # click time, so rendering the grid needs no liveness query per tile.
  #
  # ITS OWN PATH, NOT `?view=models` on FilesController: `view` is the Library's list/grid toggle and
  # lives in the `files_view` cookie, and this page's `q`/`sort` mean different things from the
  # Library's (config/routes.rb). The sidebar lights the 3D models place for it, not Library
  # (ShellHelper#sidebar_current).
  class ModelsController < ApplicationController
    SORTS = { "recent" => { updated_at: :desc }, "title" => { title: :asc },
              "status" => { print_status: :asc, title: :asc } }.freeze

    # THE FOUR FILTERS, AS STRINGS OR NOT AT ALL. A crafted `?q[a]=b` arrives as a hash, and handed to
    # the status chips' files_models_path it raised "unable to convert unpermitted parameters to hash" —
    # a 500, found in slice 5's review and older than it (carried over from /models). Anything that is
    # not a String is simply absent, here and in ModelsController#index's redirect.
    FILTERS = %w[q status tag sort].freeze

    def index
      @filters = FILTERS.to_h { |key| [ key.to_sym, (params[key] if params[key].is_a?(String)) ] }.compact
      models = current_user.maker_models.catalogued.includes(:file_attachments)
      models = models.by_status(@filters[:status])
      # THE FILES IDIOM: LOWER on both sides, ESCAPE so sanitize_sql_like means something on SQLite,
      # capped like every other search box. This clause predates the idiom; /search previews a query
      # escaped and its "See all" landed here unescaped, so `100%` matched on one page and not the
      # other (found in review, S2-5).
      q = @filters[:q].to_s.strip.first(80)
      if q.present?
        models = models.where("LOWER(title) LIKE ? ESCAPE '\\'", "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%")
      end
      if @filters[:tag].present?
        # Maker::Taggable#tagged_with (stage 2, S2-5) -- same SQL this join always ran, now shared
        # with Project and InventoryItem rather than reimplemented per controller.
        models = models.tagged_with(@filters[:tag])
      end
      @models = models.order(SORTS.fetch(@filters[:sort], SORTS["recent"])).to_a
      # AN AUTO MODEL WITH NO ATTACHMENTS IS AN EMPTIED FOLDER, and it is hidden rather than dismissed
      # or destroyed: the row keeps the user's title and tags and returns the moment a file does. The
      # rows themselves are cleared on the ordinary schedule by Maker::AttachmentReaper once the
      # tombstones age out, so this is a display rule and not a second reaper. Filtering in Ruby off
      # the ALREADY-LOADED :file_attachments include -- a `where.missing` would be a second query and
      # would disagree with what the cards render.
      @models.reject! { |m| m.auto? && m.file_attachments.empty? }
      # GROUPED BY PROJECT (Maker::ModelProjects), AFTER every filter and the sort: an empty group never
      # renders, and the chosen sort holds inside each one.
      @groups = Maker::ModelProjects.group(current_user, @models)
      @covers = Maker::Previews::ThumbnailMap.for(current_user, @models.map(&:cover_node_id))
      @all_tags = current_user.maker_tags.order(:name).pluck(:name)
      @status = @filters[:status]
    end
  end
end
