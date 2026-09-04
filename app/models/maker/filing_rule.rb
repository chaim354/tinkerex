module Maker
  # One user's answer to "which subfolder of `Projects/<slug>/` does THIS extension file into" —
  # stage 3, S3-1's per-user extension map (spec §3, §5). `Maker::ProjectFolders::ROLE_FOLDERS`
  # seeds a row per `Maker::FileAttachment::ROLE_BY_EXT` extension on a user's first read
  # (`Maker::FilingRules.seed!`); after that these rows are the truth `Maker::ProjectFolders
  # .folder_for` reads, edited at /settings/filing (`Settings::FilingRulesController`). An
  # extension with no rule here files into "other" — see `Maker::ProjectFolders` for why that is
  # a per-user CHOICE now rather than a totality the app enumerates in code.
  class FilingRule < ApplicationRecord
    self.table_name = "maker_filing_rules"

    belongs_to :user

    # ".STL" typed into the settings form and "stl" from the seed must land on the SAME row, so
    # normalization runs before either validation or save. `delete_prefix(".")`, NOT `delete(".")`
    # (which `Maker::FileAttachment.role_for` uses to strip a `File.extname`): a leading dot is the
    # only one a human could type here, and stripping every dot would mangle a name no entry in
    # ROLE_BY_EXT holds anyway.
    normalizes :ext, with: ->(e) { e.to_s.strip.downcase.delete_prefix(".") }
    normalizes :folder, with: ->(f) { f.to_s.strip.downcase }

    # THE SAME BOUND EVERY ROLE_BY_EXT ENTRY ALREADY MEETS (docs/invariants/files-preview.md) —
    # referencing the controller's own constant, never a second copy of the regex: an extension
    # this validation accepted but FilesController::EXT_RE rejected would seed a rule the Files
    # page's own filter chip could never link to.
    validates :ext, presence: true, format: { with: FilesController::EXT_RE }
    validates :ext, uniqueness: { scope: :user_id }
    validates :folder, presence: true
    validate :folder_is_a_plain_segment

    private

    # THE SAME TWO QUESTIONS EVERY OTHER LEAF-NAME DOOR ASKS — Maker::MoveNode.valid_leaf_name?
    # for syntax, Library::ReservedNames.reserved? for the library's own namespace — the identical
    # pair Maker::Shelf#path_segments_are_allowed composes for a shelf path segment, plus a bare
    # slash refusal: a folder here is ONE path segment, not a path, since #place resolves it as a
    # single child of the project's own folder node and ProjectFolders::ROLE_FOLDERS' own comment
    # already requires every folder name to be "a single lowercase path segment."
    def folder_is_a_plain_segment
      return if folder.blank? # presence: true already reports this

      ok = Maker::MoveNode.valid_leaf_name?(folder) && !folder.include?("/") &&
           !Library::ReservedNames.reserved?(folder)
      errors.add(:folder, "isn't allowed - #{folder.inspect} can't be a folder name") unless ok
    end
  end
end
