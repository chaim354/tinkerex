module Maker
  # THE RELEASE COMPOSER'S TAG PICKER, AS DATA: [[dir name, dir node_id, [tag names]]] for every
  # readable working tree nested in the project's folder, or [] where the library is not a local
  # folder (git-editing.md: asked of the CAPABILITY, never of an adapter class). Elsewhere the
  # composer takes a tag as free text and the snapshot records it unverified.
  #
  # A NAMED SERVICE BECAUSE A SECOND DOOR NEEDS IT (2026-11-02, the UX audit's B3): a refused release
  # re-renders its composer from Projects::ReleasesController, and the picker must come back holding
  # the tag that was chosen — the same options ProjectsController#show builds in
  # #release_repo_tags, which reuses the dirs and nodes its repository cards already collected. This
  # is that method's answer for a caller with no cards in hand: the same walk (NESTED working trees,
  # the folder's own root not among them), one batched `nodes` query, and the same rescue per
  # repository, so the two cannot offer different tags.
  #
  # RESCUED PER REPOSITORY, NOT AROUND THE LOOP: one unreadable working tree must cost its own tags,
  # not every other repository's. `refusal` is asked FIRST, before rugged, the order every caller of
  # Maker::Git::LocalRepo keeps (a locked repository is refused rather than opened).
  class ReleaseTags
    def self.for(user:, listing:, capabilities:)
      return [] unless capabilities.local_worktree?

      dirs = repo_dirs(listing.tree)
      return [] if dirs.empty?

      roots = user.nodes.present.where(node_id: dirs.map(&:node_id), kind: "dir").index_by(&:node_id)
      dirs.filter_map do |dir|
        root = roots[dir.node_id]
        next if root.nil?

        tags = begin
          local = Maker::Git::LocalRepo.open(user, root)
          local.refusal ? [] : local.tags.map(&:name)
        rescue StandardError => e
          Rails.logger.warn("[releases] tags unreadable for #{dir.name}: #{e.class} #{e.message}")
          []
        end
        tags.any? ? [ dir.name, dir.node_id, tags ] : nil
      end
    end

    def self.repo_dirs(dirs) = dirs.flat_map { |d| (d.repo? ? [ d ] : []) + repo_dirs(d.children) }
    private_class_method :repo_dirs
  end
end
