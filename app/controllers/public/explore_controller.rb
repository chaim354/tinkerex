module Public
  # GET /explore(?tag=) — everyone's public projects, newest first, filterable by tag.
  #
  # `publicly_listed` on BOTH the list and the chips: a chip counting an unlisted or private
  # project's tag would leak that the project exists, and a tag whose only wearer is private would
  # render a chip leading to an empty page.
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
