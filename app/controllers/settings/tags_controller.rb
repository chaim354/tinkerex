module Settings
  # Every tag the user owns, with how many things wear it, and a Remove that takes the taggings
  # with the tag (Maker::Tag has_many :taggings, dependent: :destroy) and nothing else — the
  # project, model or item keeps everything but the chip.
  class TagsController < ApplicationController
    def index
      @tags = current_user.maker_tags.order(:name).to_a
      @counts = current_user.maker_taggings.group(:tag_id).count # ONE query
    end

    # SCOPED THROUGH current_user, NEVER Maker::Tag.find -- a foreign id must 404, not resolve
    # another user's row (the same argument SuppliersController#destroy and LocationsController
    # #destroy make for their own scoped lookups).
    def destroy
      tag = current_user.maker_tags.find(params[:id])
      tag.destroy!
      redirect_to settings_tags_path, notice: "Removed the tag #{tag.name}."
    end
  end
end
