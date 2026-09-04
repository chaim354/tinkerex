module Maker
  # What a taggable thing shares (stage 2, S2-5): the polymorphic edge onto Maker::Tag, the
  # comma-separated `tag_list` the forms edit, and the deferred apply that makes it safe on a new,
  # unsaved record. Lifted from Maker::Model verbatim, where models/_form has used it since the
  # catalog shipped; Project and InventoryItem include it now. A tag name is whatever Maker::Tag
  # normalizes (stripped, downcased), unique per user, find-or-created on write.
  #
  # Maker::Item (the desktop client's catalog) is DELIBERATELY NOT included here -- it already
  # carries its own taggings/tags associations, driven by the v1 JSON API's TaggingsController
  # rather than a comma-separated form field, and has no tag_list of its own to unify.
  module Taggable
    extend ActiveSupport::Concern

    included do
      has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
      has_many :tags, through: :taggings, class_name: "Maker::Tag"
      after_save :apply_pending_tag_list

      # Rows wearing the tag NAMED here (normalized the way Tag stores it); a name nobody uses is
      # an empty set, not an error. ONE join, no subquery per row.
      scope :tagged_with, ->(name) {
        joins(:tags).where(maker_tags: { name: name.to_s.strip.downcase })
      }
    end

    def tag_list = tags.map(&:name).sort.join(", ")

    # DELIBERATELY NOT an endless method (`def tag_list=(str) = ...`) -- Ruby refuses to define a
    # SETTER as an endless method at all ("invalid method name; a setter method cannot be defined
    # in an endless method definition"), a SyntaxError this file's own plan text got wrong when it
    # compressed the method onto one line. Maker::Model's original carried this exact multi-line
    # form; kept verbatim.
    def tag_list=(str)
      @tag_list_pending = str
    end

    private

    def apply_pending_tag_list
      return unless defined?(@tag_list_pending)
      names = @tag_list_pending.to_s.split(",").map { |n| n.strip.downcase }.reject(&:blank?).uniq
      wanted = names.map { |n| user.maker_tags.find_or_create_by!(name: n) }
      transaction do
        taggings.where.not(tag_id: wanted.map(&:id)).destroy_all
        wanted.each { |t| taggings.find_or_create_by!(user: user, tag: t) }
      end
      remove_instance_variable(:@tag_list_pending)
    end
  end
end
