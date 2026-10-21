module Maker
  # One user's answer to "which subfolder of `Projects/<slug>/` does THIS extension file into" —
  # stage 3, S3-1's per-user extension map (spec §3, §5). `Maker::ProjectFolders::ROLE_FOLDERS`
  # seeds a row per `Maker::FileAttachment::ROLE_BY_EXT` extension on a user's first read
  # (`Maker::FilingRules.seed!`); after that these rows are the truth `Maker::ProjectFolders
  # .folder_for` reads, edited as the extension chips on the Shelves page (/settings/shelves; the
  # chips post to `Settings::FilingRulesController`). `folder` names a Maker::Shelf by string. An
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

    # THE FILING MAP'S OWN KEY RULE, WIDER THAN `FilesController::EXT_RE` ON PURPOSE (stage 4,
    # S4-2). A key here is an EXTENSION as `Maker::ProjectFolders.ext_of` reads it — everything
    # after the last dot, downcased — and two formats a maker actually has, `.kicad_sch` and
    # `.kicad_pcb`, are nine characters with an underscore. `EXT_RE` (/\A[a-z0-9]{1,8}\z/) is the
    # FILES PAGE's bound and is right there: an extension it rejects renders a filter chip that
    # links and silently does nothing, which is why `Maker::FileAttachment::ROLE_BY_EXT` must meet
    # it (docs/invariants/files-preview.md, and file_attachment_test.rb's own guard).
    #
    # A FILING RULE RENDERS NO CHIP AND GRANTS NO ROLE. It answers exactly one question — which
    # subfolder — so it can carry a key the vocabulary cannot. That is the split, and it is NOT a
    # second copy of EXT_RE drifting: EXT_RE is untouched, still referenced by ROLE_BY_EXT's own
    # guard, and nothing here loosens it. A `.kicad_sch` file's ROLE stays `other` and its FOLDER
    # is `pcb` — two questions, two answers, which is the same shape `.scad` already carries
    # (`cad_source` for filing, text for viewing).
    #
    # 12, NOT UNBOUNDED, AND THE UNDERSCORE IS THE ONLY CHARACTER ADDED. `kicad_sch`/`kicad_pcb`
    # are 9; 12 leaves headroom without letting a pasted filename become a key. No dot (a dot
    # would admit `tar.gz`, which `ext_of` can never produce), no dash, no space.
    KEY_RE = /\A[a-z0-9_]{1,12}\z/

    validates :ext, presence: true, format: { with: KEY_RE }
    validates :ext, uniqueness: { scope: :user_id }
    validates :folder, presence: true
    validate :folder_is_a_plain_segment

    # ONE PATH SEGMENT THE LIBRARY WILL ACCEPT AS A FOLDER NAME. Shared with Maker::Shelf, whose
    # name IS the folder these rules file into, so the two can never disagree about what a valid
    # folder is.
    def self.plain_segment?(name)
      Maker::MoveNode.valid_leaf_name?(name) && !name.include?("/") &&
        !Library::ReservedNames.reserved?(name)
    end

    private

    # THE SAME TWO QUESTIONS EVERY OTHER LEAF-NAME DOOR ASKS — Maker::MoveNode.valid_leaf_name?
    # for syntax, Library::ReservedNames.reserved? for the library's own namespace — plus a bare
    # slash refusal, spelled once in .plain_segment? and asked by Maker::Shelf too: a folder here is
    # ONE path segment, not a path, since #place resolves it as a single child of the project's own
    # folder node and ProjectFolders::ROLE_FOLDERS' own comment already requires every folder name
    # to be "a single lowercase path segment."
    def folder_is_a_plain_segment
      return if folder.blank? # presence: true already reports this

      ok = self.class.plain_segment?(folder)
      errors.add(:folder, "isn't allowed - #{folder.inspect} can't be a folder name") unless ok
    end
  end
end
