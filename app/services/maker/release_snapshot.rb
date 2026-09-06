module Maker
  # CREATES A RELEASE FROM WHAT THE PROJECT HOLDS RIGHT NOW (stage 3, S3-5; spec §2.3, §3). One
  # folder listing, ONE `stat_all` over its rows — never one `stat` per file, the same constancy
  # rule the pages keep — the current BOM's id and revision, and the tag resolved against the
  # repository the maker picked. Refuses, rather than records, a tag that does not exist in a
  # repository it can read.
  #
  # NO BYTES MOVE AND NONE ARE COPIED. What is stored per file is its node id and the content token
  # the port reported at this moment; a download later delivers the CURRENT file through the
  # ordinary blob route, and the page compares tokens to say "changed since this release". On
  # chunk_remote that token is the sync server's version id, answered from the local mirror (§14a);
  # on share/s3 it is the content hash, which identifies bytes without implying they are recoverable.
  class ReleaseSnapshot
    class TagNotFound < StandardError; end

    Result = Data.define(:release, :file_count, :tag_verified)

    def self.call(user:, project:, version:, notes: nil, git_tag: nil, repo_node_id: nil)
      new(user:, project:).call(version:, notes:, git_tag:, repo_node_id:)
    end

    def initialize(user:, project:)
      @user = user
      @project = project
      @listing = Maker::ProjectFolderListing.new(user, project)
    end

    def call(version:, notes:, git_tag:, repo_node_id:)
      git_oid, verified = resolve_tag(git_tag, repo_node_id)
      bom = @project.current_bom
      # Backups are the folder's rescue copies (LightBurn/MillMage), diverted out of the tree by
      # the listing itself; a release lists what the maker made, not what an editor left behind.
      rows = @listing.all_rows.reject(&:backup?)
      info = rows.empty? ? {} : FileLayer.current.stat_all(@user, node_ids: rows.map(&:node_id))

      release = nil
      # THE TRANSACTION IS WHAT MAKES A REFUSED RELEASE LEAVE NOTHING BEHIND. `resolve_tag` raises
      # before it opens, so the ordinary refusal never reaches here; this covers the file rows,
      # which must not exist without their release nor the release without them.
      Maker::Release.transaction do
        release = @project.releases.create!(user: @user, version:, git_tag:, git_oid:,
                                            repo_node_id: (git_tag.presence && repo_node_id.presence),
                                            bom:, bom_revision: bom&.revision,
                                            published_at: Time.current, notes:)
        now = Time.current
        # `stat_all` answers with an ABSENT KEY for a node it cannot see (§14a), never a raise, so
        # a row tombstoned between the listing and the stat is skipped rather than fatal.
        records = rows.filter_map do |row|
          stat = info[row.node_id] or next
          { user_id: @user.id, release_id: release.id, node_id: row.node_id, name: row.node.name,
            path: relative_path(row), content_token: stat.content_token, size: stat.size,
            created_at: now, updated_at: now }
        end
        Maker::ReleaseFile.insert_all(records) if records.any?
      end
      Result.new(release:, file_count: release.files.count, tag_verified: verified)
    end

    private

    # [oid, verified?]. Where the library is a local folder the tag must exist in the picked repo
    # (TagNotFound otherwise); elsewhere the tag is recorded as typed and verified is false — the
    # repo card's own rule (docs/invariants/git-editing.md), asked of the CAPABILITY and never of an
    # adapter class.
    def resolve_tag(git_tag, repo_node_id)
      return [ nil, false ] if git_tag.blank?
      return [ nil, false ] unless FileLayer.current.capabilities.local_worktree? && repo_node_id.present?

      root = @user.nodes.present.find_by(node_id: repo_node_id, kind: "dir")
      raise TagNotFound, "no repository at #{repo_node_id}" if root.nil?

      local = Maker::Git::LocalRepo.open(@user, root)
      # `refusal` FIRST, then rugged — the order every caller of this class must keep, because
      # constructing anything past it dereferences the port's workdir on the way to libgit2. A
      # locked repository is refused, never unlocked (git-editing.md).
      raise TagNotFound, local.refusal if local.refusal

      tag = local.tags.find { |t| t.name == git_tag }
      raise TagNotFound, "no tag #{git_tag} in #{root.name}" if tag.nil?

      [ tag.oid, true ]
    end

    # THE FOLDER-RELATIVE PATH, READ OFF THE ROW THE LISTING ALREADY BUILT. `Row#section` is that
    # display path ("" for a root/loose row), computed once while the tree was walked — so this
    # costs nothing and cannot disagree with what the panel showed. `listing.path_for(node)` is the
    # wrong instrument here: it answers the PARENT dir's FULL library path
    # ("Projects/desk-lamp/models"), for the Linked group's rows that live outside the folder.
    def relative_path(row)
      row.section.presence ? "#{row.section}/#{row.node.name}" : row.node.name
    end
  end
end
