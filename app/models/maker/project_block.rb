module Maker
  # A CONTENT BLOCK ON A PROJECT'S PAGE (2026-09-09, content blocks; spec §2, §4). Three kinds in
  # one table because they are arranged as one thing — a block sits in the page's order beside the
  # panels under `block:<key>` — and the kind decides which columns mean anything. The fields are
  # checked AGAINST the kind here, the second lock behind Maker::LayoutDocument's first, so no door
  # (Save, a console, the v1 API later) can store a link without a URL.
  #
  # `key` IS THE LAYOUT'S HANDLE, not `id`: it is minted here, it appears in the YAML as `id:` so a
  # pasted layout can name a block it came from, and a row id would leak ordinal facts about the
  # database into a shareable text.
  #
  # Markdown in `body` is rendered on every read through Maker::Markdown, which sanitises; nothing
  # here is trusted as HTML.
  class ProjectBlock < ApplicationRecord
    self.table_name = "maker_project_blocks"

    KINDS = %w[text link image].freeze
    HEADING_MAX = 80
    LINE_MAX = 200
    BODY_MAX = 20 * 1024
    CAP = 40
    KEY_FORMAT = /\A[0-9a-f]{12}\z/
    URL_FORMAT = %r{\Ahttps?://[^\s/]+\S*\z}

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    normalizes :heading, :url, :line, :caption, with: ->(s) { s.to_s.gsub(/\s+/, " ").strip.presence }

    before_validation { self.key = self.class.new_key if key.blank? }

    validates :kind, inclusion: { in: KINDS }
    validates :key, presence: true, format: { with: KEY_FORMAT }, uniqueness: { scope: :project_id }
    validates :heading, length: { maximum: HEADING_MAX }
    validates :line, :caption, length: { maximum: LINE_MAX }
    validates :body, length: { maximum: BODY_MAX }
    validate :fields_match_kind
    validate :project_belongs_to_user

    def self.new_key = SecureRandom.hex(6)

    def layout_key = Maker::ProjectKind.block_key(key)

    private

    def fields_match_kind
      case kind
      when "text"
        errors.add(:body, "or a heading is required for a text block") if body.blank? && heading.blank?
      when "link"
        errors.add(:url, "must be an http or https URL") unless url.to_s.match?(URL_FORMAT) && URI.parse(url).host.present?
        errors.add(:heading, "is required for a link") if heading.blank?
      when "image"
        errors.add(:node_id, "is required for an image") if node_id.blank?
      end
    rescue URI::InvalidURIError
      errors.add(:url, "must be an http or https URL")
    end

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end
  end
end
