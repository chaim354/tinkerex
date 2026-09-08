module Public
  # GET /explore(?tag=) — everyone's public projects, newest first, filterable by tag.
  #
  # `publicly_listed` on BOTH the list and the chips: a chip counting an unlisted or private
  # project's tag would leak that the project exists, and a tag whose only wearer is private would
  # render a chip leading to an empty page.
  #
  # THE CARD'S COVER SLOT IS DELIBERATELY EMPTY HERE (stage 4, S4-5; that plan's Amendment 9 and
  # open question 1). Maker::Previews::ThumbnailMap is per-user — a preview row belongs to its owner
  # and the port is asked in the owner's name (§14a) — so covers on a list whose every card is a
  # DIFFERENT maker cost three statements per distinct maker (measured: 14 small / 50 large against a constant 5), linear in N. `index.html.erb` passes
  # `thumb: nil` and Public::UsersController, which is single-owner, passes a real map. Nothing
  # here reads `file_attachments` either, so they are deliberately NOT in the `includes` below: an
  # eager load nothing uses is a bigger query for no benefit. Giving /explore covers is a separate
  # decision (a per-maker map, or a CoverMap), not a line to add here.
  class ExploreController < BaseController
    PAGE = 60

    def index
      @tag = params[:tag].to_s.strip.downcase.presence
      scope = Maker::Project.publicly_listed.includes(:user, :tags)
      # Maker::Taggable#tagged_with joins maker_tags BY NAME and is not user-scoped, which is what
      # makes it correct here: /explore is cross-user by definition.
      scope = scope.tagged_with(@tag) if @tag
      @projects = scope.order(updated_at: :desc).limit(PAGE).to_a
      # Tag chips over PUBLIC projects only, most used first, capped — ONE grouped query, never one
      # count per tag. `.count` on a grouped relation answers {name => count}.
      @chips = Maker::Tag.joins(:taggings)
                         .where(maker_taggings: { taggable_type: "Maker::Project",
                                                  taggable_id: Maker::Project.publicly_listed.select(:id) })
                         .group(:name).order(Arel.sql("COUNT(*) DESC"), :name).limit(30).count
    end
  end
end
