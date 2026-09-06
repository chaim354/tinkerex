module Maker
  # One file as a release saw it (stage 3, S3-5). `node_id` is the catalog's, soft like every other
  # arrow into `nodes` — a file deleted, moved or overwritten after the release keeps this row, and
  # the panel compares `content_token` against what the port reports NOW to say "changed since".
  #
  # `path` IS THE FOLDER-RELATIVE PATH AT RELEASE TIME AND IS DELIBERATELY NOT RE-DERIVED. A node's
  # id survives a move and its path does not, so the recorded string is what the release listed;
  # rebuilding it from the catalog would silently rewrite history every time a maker tidies up.
  class ReleaseFile < ApplicationRecord
    self.table_name = "maker_release_files"

    belongs_to :user
    belongs_to :release, class_name: "Maker::Release", foreign_key: :release_id

    validates :node_id, presence: true
    validates :name, presence: true

    # "changed" / "gone" / nil, ASKED OF WHAT THE PORT REPORTS NOW -- `info` is this node's entry in
    # the ONE `stat_all` each panel takes over every release file it shows, so nil means the port
    # answered with an ABSENT KEY (§14a) and the file is no longer in the library at all.
    #
    # ONE DEFINITION FOR TWO PANELS, and that is the whole reason it is here rather than inline in
    # each. The private page and the public page both say "changed since this release", and a pair
    # of expressions that must agree is the shape this repo keeps paying for (§14a's own warning
    # about one condition with two answers). A release whose token was nil at snapshot time and is
    # nil now is UNCHANGED, which is the honest reading: the port reported the same thing twice.
    def state_against(info)
      return "gone" if info.nil?

      info.content_token == content_token ? nil : "changed"
    end
  end
end
