class AddFilesTruncatedToMakerReleases < ActiveRecord::Migration[8.1]
  def change
    # A release records the first FILE_CAP files of a larger folder and SAYS SO, permanently: the
    # flash is gone a second later and the panel is what a maker reads back (S3-5's review).
    add_column :maker_releases, :files_truncated, :boolean, null: false, default: false
  end
end
