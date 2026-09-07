module Maker
  # Every photo a project page shows (stage 4, S4-1): the folder's image-role rows plus every LIVE
  # build-log entry photo, deduped, in name order. THE ONE DEFINITION — Maker::PublicProject
  # #photo_rows delegated here the day the private page grew the same gallery, so the two pages
  # cannot drift about what counts as a photo.
  #
  # An entry photo usually lives OUTSIDE the folder (the upload door puts it wherever the maker
  # pointed it), which is why it is read from `page_nodes` — the page's one live-node union —
  # rather than from the listing. In memory over inputs the page already loaded: no query, and
  # page_query_budget_test.rb's seed grows entry photos with N to keep it that way.
  module ProjectPhotos
    def self.rows(listing:, entries:, page_nodes:)
      folder_rows = listing.all_rows.select { |r| r.role == "image" }
      entry_rows = entries.flat_map(&:file_attachments)
                          .filter_map { |a| page_nodes[a.node_id] }
                          .map { |node| Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: true, section: nil) }
      (folder_rows + entry_rows).uniq(&:node_id).sort_by { |r| r.node.name }
    end
  end
end
