require "digest"

module Maker
  # THE TIDY-UP LIST (the Shop manual's spec §9, 2026-11-19): what a project's page suggests the
  # maker sort out, as numbered cells on one plate. Three checks, each READ-ONLY — nothing here files,
  # moves, commits or creates anything, and the port is never asked for bytes:
  #
  #   loose        — a file at the project folder's root that the filing pass CANNOT file, because
  #                  the folder its rule names already holds that name (Maker::LooseFilingNotes's own
  #                  prediction, so the Files panel's row and this cell cannot disagree). Only where
  #                  filing runs: an autofile-off project files nothing by the maker's choice, and a
  #                  file inside a working tree or a model's bundle is attached and left by design
  #                  (Maker::AttachToProject#refusal_for), so none of them is a suggestion. A file
  #                  the next pass WILL file is not one either; it is the pass's job.
  #   uncommitted  — a repository in the project with changes git has not committed. Only where the
  #                  library is a local folder (`local_worktree?`, never an adapter class:
  #                  docs/invariants/git-editing.md), counted from git's own status
  #                  (Maker::Git::LocalRepo#changed_paths: no content read) less OS clutter, which
  #                  the commit page also sets apart. A hint that links the commit page, which
  #                  compares content and is the authority.
  #   export_older — a file DERIVED FROM another (Maker::FileLink `derived_from`: from = the export,
  #                  to = its source) whose mtime is older than its source's: the source changed
  #                  after the export was made. Both must be live; a nil mtime is never compared.
  #
  # THE FOURTH CHECK THE SPEC NAMES, "A SHEET THAT DISAGREES WITH A FILE", IS NOT HERE AND CANNOT BE
  # YET: a `maker_sheets` grid is free-form JSON with no link to any node and no typed cells, so
  # "disagrees" has no definition (spec §9 records what it would need).
  #
  # COST: CONSTANT IN THE NUMBER OF FILES, LINKS AND DISMISSALS (page_query_budget_test.rb). `loose`
  # reads the listing in memory plus the filing rules (two queries, shared in kind with the Files
  # panel), one ancestor walk for the folder (Library::WorkingTree, memoised on the parent every root
  # file shares) and one batched bundle lookup — the last two only when some file is blocked.
  # `export_older` is ONE query over the links joined to `nodes` at both ends. `uncommitted` is ONE
  # grouped query over the pending edits and one git status per repository, which is a disk walk and
  # no SQL. The dismissals are ONE query, asked only when there is a suggestion to ask about.
  #
  # DISMISSED SUGGESTIONS LEAVE THE LIST WHILE THEIR STATE IS UNCHANGED (Maker::TidyDismissal says
  # what each state is). `all` keeps them, because the dismissal door must find the suggestion it is
  # dismissing and store the state THIS computed, never one a browser sent.
  class TidyUp
    KINDS = %w[loose uncommitted export_older].freeze

    # A project page with more than this many suggestions shows the first ones and says how many
    # wait; dealing with one brings the next in. Enough for a row and a half of cells.
    SHOWN = 12

    # `since` is set only for `uncommitted`: the newest pending edit this app saved into that
    # repository, which a dismissal must be newer than (Maker::TidyDismissal's header).
    Suggestion = Data.define(:kind, :subject, :state, :detail, :since) do
      def initialize(since: nil, **fields) = super(since:, **fields)
    end

    # `node` is the loose file; `blocked_by` the library-relative path inside the project folder
    # that is taken ("design/x.svg"); `dir` the Dir of the folder it would be filed into.
    Loose = Data.define(:node, :blocked_by, :dir)
    # `name` is the repository's folder name; `root` true when the repository IS the project folder.
    Uncommitted = Data.define(:root_node_id, :name, :count, :root)
    ExportOlder = Data.define(:derived_id, :derived_name, :source_id, :source_name)

    # A repository the page knows about: its root dir's Node (for LocalRepo), the name to show, and
    # whether it is the project folder itself.
    Repo = Data.define(:node, :name, :root)

    # The export and its source, both live, the export older than the source — the one definition of
    # "an export older than its source", shared by the project page and Home. Rows are
    # [from_node_id, to_node_id, derived name, source name, source mtime, derived parent, source parent].
    # The aliases are `derived_node` and `source_node`, never bare `source`, a keyword (non-reserved)
    # in Postgres's MERGE grammar. `deleted = :no` with a bound false, never a literal: SQLite stores the flag as 0/1 and Postgres
    # as a boolean, and a bind is quoted right on both (§14e: adapter-agnostic SQL).
    STALE_LINK_JOINS = <<~SQL.squish.freeze
      INNER JOIN nodes derived_node ON derived_node.user_id = maker_file_links.user_id
                                   AND derived_node.node_id = maker_file_links.from_node_id
                                   AND derived_node.deleted = :no
      INNER JOIN nodes source_node ON source_node.user_id = maker_file_links.user_id
                                  AND source_node.node_id = maker_file_links.to_node_id
                                  AND source_node.deleted = :no
    SQL
    STALE_LINK_COLUMNS = %w[maker_file_links.from_node_id maker_file_links.to_node_id derived_node.name
                            source_node.name source_node.mtime derived_node.parent_node_id
                            source_node.parent_node_id].freeze

    def self.stale_links(user)
      Maker::FileLink.where(user_id: user.id, kind: "derived_from")
                     .joins(ActiveRecord::Base.sanitize_sql([ STALE_LINK_JOINS, { no: false } ]))
                     .where("derived_node.mtime IS NOT NULL AND source_node.mtime IS NOT NULL " \
                            "AND derived_node.mtime < source_node.mtime")
    end

    # A subject for a pair: the export's node id, then its source's. `>` appears in no node id.
    def self.link_subject(from_id, to_id) = "#{from_id}>#{to_id}"

    # The digest that stands for a set of changed paths: short, stable, and different the moment the
    # set is. The paths arrive sorted (LocalRepo#changed_paths).
    def self.paths_state(paths) = Digest::SHA256.hexdigest(paths.join("\n"))[0, 16]

    # Is this dismissal still in force for this suggestion? The state must match, and for a
    # repository the dismissal must be newer than the newest edit this app saved there. `state: false`
    # is Home's NOT COMMITTED, which has no git digest to compare (TidyUp::Attention says why).
    def self.dismissed?(dismissal, suggestion, state: true)
      return false if dismissal.nil?
      return false if state && dismissal.state != suggestion.state

      suggestion.since.nil? || dismissal.updated_at >= suggestion.since
    end

    # The repositories a project's folder holds, as Repo values for `repos:` — the folder itself when
    # it is a working tree, then every working tree inside it (ProjectFolderListing#repos, in memory).
    # Their Nodes come from `nodes:` when the caller already loaded them (ProjectsController#show's
    # repository cards batch the same lookup), else from ONE query here. Nothing where the library is
    # not a local folder: git is not asked there, so neither is the database.
    def self.repos_in(user, listing, project, nodes: nil, capabilities: FileLayer.current.capabilities)
      return [] unless capabilities.local_worktree? && listing.available?

      wanted = (listing.root_repo? ? [ [ listing.folder_id, project.name, true ] ] : []) +
               listing.repos.map { |repo| [ repo.node_id, repo.name, false ] }
      return [] if wanted.empty?

      nodes ||= user.nodes.present.where(node_id: wanted.map(&:first), kind: "dir").index_by(&:node_id)
      wanted.filter_map { |id, name, root| nodes[id] && Repo.new(node: nodes[id], name:, root:) }
    end

    # `repos:` are the repositories the page found (the controller already holds their Nodes for the
    # repository cards, so passing them costs nothing). `capabilities:` decides whether git is asked.
    def self.for(user:, project:, listing:, repos: [], capabilities: FileLayer.current.capabilities)
      new(user:, project:, listing:, repos:, capabilities:)
    end

    attr_reader :all, :suggestions

    def initialize(user:, project:, listing:, repos:, capabilities:)
      @user = user
      @project = project
      @listing = listing
      @repos = repos
      @capabilities = capabilities
      @all = loose + uncommitted + export_older
      @suggestions = undismissed(@all)
    end

    def any? = @suggestions.any?
    def count = @suggestions.size
    def shown = @suggestions.first(SHOWN)

    # The suggestion of this kind about this subject, dismissed or not; nil when the checks no longer
    # raise it (fixed since the page was drawn).
    def find(kind, subject) = @all.find { |s| s.kind == kind && s.subject == subject }

    private

    def loose
      return [] unless @listing.available? && @project.autofile? && !@listing.root_repo?

      blocked = Maker::LooseFilingNotes.blocked(user: @user, listing: @listing, rows: @listing.loose)
      return [] if blocked.empty?

      rows = @listing.loose.select { |row| blocked.key?(row.node_id) }
      # THE REFUSALS THAT COME BEFORE THE COLLISION (Maker::ProjectIntake#place asks
      # AttachToProject#refusal_for first): a file inside a working tree or a model's bundle is
      # attached and left, so the collision is never reached. Asked of the batch rather than per row
      # through #refusal_for, whose bundle lookup is a query per file: every loose row shares the
      # folder as its parent, so ONE walk answers the first for all of them, and ONE pluck the second.
      return [] if Library::WorkingTree.new(@user).in_working_tree?(rows.first.node)

      bundled = @user.maker_file_attachments.where(node_id: rows.map(&:node_id), attachable_type: "Maker::Model")
                     .pluck(:node_id).to_set
      rows.reject { |row| bundled.include?(row.node_id) }.map do |row|
        hit = blocked.fetch(row.node_id)
        path = "#{hit.folder}/#{row.node.name}"
        Suggestion.new(kind: "loose", subject: row.node_id, state: path,
                       detail: Loose.new(node: row.node, blocked_by: path, dir: hit.dir))
      end
    end

    def uncommitted
      return [] unless @capabilities.local_worktree? && @repos.any?

      changed = @repos.filter_map do |repo|
        paths = changed_paths(repo.node)
        [ repo, paths ] if paths.present?
      end
      return [] if changed.empty?

      # The newest edit this app saved into each changed repository: ONE grouped query, the time a
      # dismissal must be newer than (Maker::TidyDismissal). Asked only once git has found something.
      pending = self.class.pending_edits(@user, changed.map { |repo, _| repo.node.node_id })
      changed.map do |repo, paths|
        id = repo.node.node_id
        Suggestion.new(kind: "uncommitted", subject: id, state: self.class.paths_state(paths), since: pending.dig(id, 1),
                       detail: Uncommitted.new(root_node_id: id, name: repo.name, count: paths.size, root: repo.root))
      end
    end

    # git's changed paths less OS clutter, or nil when the repository cannot be read. A suggestion
    # list must never take the page down, so every failure Maker::RepoCard degrades on is nil here
    # too, and an unreachable store is named by the layout's banner exactly as the card names it.
    def changed_paths(node)
      Maker::Git::LocalRepo.open(@user, node).changed_paths.reject { |rel| Library::OsClutter.ignore?(rel) }
    rescue FileLayer::FetchError
      Current.library_unreachable = true
      nil
    rescue Rugged::Error, Rugged::OSError, FileLayer::NotFound
      nil
    end

    def export_older
      return [] unless @listing.available?

      # EVERY DIR THE LISTING WALKED, so a link with either end anywhere in the folder counts — the
      # folder itself and each subfolder's subtree, in memory over the tree already built. Bounded by
      # the listing's DIR_CAP, like everything else the page lists.
      dirs = [ @listing.folder_id ] + @listing.tree.flat_map(&:subtree_dir_ids)
      self.class.stale_links(@user)
          .where("derived_node.parent_node_id IN (:dirs) OR source_node.parent_node_id IN (:dirs)", dirs:)
          .order("derived_node.name", "maker_file_links.id")
          .pluck(*STALE_LINK_COLUMNS.map { |c| Arel.sql(c) })
          .map do |from_id, to_id, derived_name, source_name, source_mtime, _dp, _sp|
            Suggestion.new(kind: "export_older", subject: self.class.link_subject(from_id, to_id),
                           state: source_mtime.to_s,
                           detail: ExportOlder.new(derived_id: from_id, derived_name:, source_id: to_id, source_name:))
          end
    end

    def undismissed(candidates)
      return [] if candidates.empty?

      dismissals = @project.tidy_dismissals.where(subject: candidates.map(&:subject).uniq)
                           .index_by { |d| [ d.kind, d.subject ] }
      candidates.reject { |s| self.class.dismissed?(dismissals[[ s.kind, s.subject ]], s) }
    end

    class << self
      # repo root node id => [how many pending edits, the newest one's time], among LIVE files: ONE
      # grouped query, shared by the project page and Home. A pending edit counts only while its file is
      # live (RepoCommitsController#pending_paths drops the rest), so its time must come from a live one.
      # `root_ids: nil` asks about every repository the user has pending edits in (Home). The MAX comes
      # back as the adapter returns it (a string on SQLite), so it is cast by the column's own type.
      def pending_edits(user, root_ids = nil)
        scope = Maker::RepoEdit.where(user_id: user.id).joins(live_edit_join)
        scope = scope.where(repo_root_node_id: root_ids) if root_ids
        type = Maker::RepoEdit.type_for_attribute(:updated_at)
        scope.group("maker_repo_edits.repo_root_node_id")
             .pluck(Arel.sql("maker_repo_edits.repo_root_node_id"), Arel.sql("COUNT(*)"),
                    Arel.sql("MAX(maker_repo_edits.updated_at)"))
             .to_h { |root, n, newest| [ root, [ n.to_i, type.deserialize(newest) ] ] }
      end

      private

      def live_edit_join
        ActiveRecord::Base.sanitize_sql([ <<~SQL.squish, { no: false } ])
          INNER JOIN nodes edited ON edited.user_id = maker_repo_edits.user_id
                                 AND edited.node_id = maker_repo_edits.node_id
                                 AND edited.deleted = :no
        SQL
      end
    end
  end
end
