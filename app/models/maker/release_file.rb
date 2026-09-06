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
  end
end
