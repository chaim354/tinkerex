module Maker
  # A RELEASE IS A SNAPSHOT OF REFERENCES, NEVER OF BYTES (stage 3, S3-5; spec §2.3, §3): the
  # version the maker named, the git tag and the commit it pointed at, the BOM revision that was
  # current, and one row per file with the content token the port reported at that moment. The
  # bytes stay where they are; a download delivers the current file, and the page compares tokens.
  class Release < ApplicationRecord
    self.table_name = "maker_releases"

    VERSION_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,39}\z/

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"
    belongs_to :bom, class_name: "Maker::Bom", optional: true
    has_many :files, -> { order(:path, :name) }, class_name: "Maker::ReleaseFile",
             foreign_key: :release_id, dependent: :destroy
    has_rich_text :notes
    include Maker::TextOnlyRichText
    # NOT `body`, which is the concern's default and what the other two including models carry.
    self.text_only_rich_text_attribute = :notes

    normalizes :version, with: ->(v) { v.to_s.strip }
    normalizes :git_tag, with: ->(t) { t.to_s.strip.presence }
    validates :version, presence: true,
              format: { with: VERSION_RE,
                        message: "is letters, digits, dots, dashes and underscores, up to 40" },
              uniqueness: { scope: %i[user_id project_id],
                            message: "is already a release of this project" }
    validates :published_at, presence: true
    validate :project_belongs_to_user

    def short_oid = git_oid.to_s[0, 8].presence

    private

    # §14d: a `*_belongs_to_user` check guarded on the fk's presence makes a DANGLING id lock the
    # whole row, so `Maker::Project` must carry a `dependent:` for this association — it carries
    # `:destroy`, since a release of a project that no longer exists is nothing.
    def project_belongs_to_user
      return if project_id.nil? || Maker::Project.exists?(id: project_id, user_id: user_id)

      errors.add(:project_id, "must reference your own project")
    end
  end
end
