module Maker
  class TidyUp
    # HOME'S HALF OF THE TIDY-UP LIST (the Shop manual's §9, 2026-11-19): the NOT COMMITTED and OUT OF
    # DATE rows "Needs attention" carries, across every project, in a CONSTANT number of queries —
    # Home lists every project at once, so nothing here may cost a query, or a git walk, per project
    # (page_query_budget_test.rb).
    #
    # OUT OF DATE is the project page's own check, whole: Maker::TidyUp.stale_links is one query over
    # the links joined to `nodes` at both ends, and its state (the source's mtime) is the one a
    # dismissal on the project page stored, so a dismissed suggestion is gone here too.
    #
    # NOT COMMITTED IS A HINT HERE, AND ITS SENTENCE SAYS SO. The project page asks git; Home must not
    # (a working-tree walk per repository, per visit, on a NAS). What Home can ask in one query is
    # Maker::RepoEdit — the files THIS APP saved into a repository and has not seen committed — so
    # the row counts those and words them as such ("2 files saved in Tinkerex are not committed").
    # Changes made in another editor are the project page's to report. A dismissal hides the row
    # while it is newer than the newest such save, which is the same rule the project page adds to its
    # own state check, so a dismissed repository leaves both pages and a new save brings it back to
    # both. Asked only where the library is a local folder: elsewhere there is no commit page and the
    # app records no pending edit at all (Maker::TextSave).
    #
    # A ROW BELONGS TO THE PROJECT WHOSE FOLDER HOLDS IT — the nearest one above the export (else its
    # source), or above the repository's root — found by walking Maker::LibraryTree in memory against
    # the projects' folder ids. An archived project raises nothing here. Both lists are fetched up to
    # FETCH_CAP rows before the dismissals are taken out, so the rows shown are bounded and a library
    # with thousands of stale exports still costs the same queries.
    class Attention
      Row = Data.define(:kind, :project, :detail)
      # `count` pending saves in the repository at `root_node_id`, under `name`.
      Pending = Data.define(:root_node_id, :name, :count)

      FETCH_CAP = 200

      def self.for(user, limit:, capabilities: FileLayer.current.capabilities)
        new(user, capabilities:).rows.first(limit)
      end

      def initialize(user, capabilities:)
        @user = user
        @capabilities = capabilities
      end

      def rows
        exports = TidyUp.stale_links(@user).order(Arel.sql("source_node.mtime DESC"), "maker_file_links.id")
                        .limit(FETCH_CAP).pluck(*TidyUp::STALE_LINK_COLUMNS.map { |c| Arel.sql(c) })
        pending = @capabilities.local_worktree? ? TidyUp.pending_edits(@user).first(FETCH_CAP) : []
        return [] if exports.empty? && pending.empty?

        candidates = uncommitted_rows(pending) + export_rows(exports)
        return [] if candidates.empty?

        dismissals = @user.maker_tidy_dismissals.where(subject: candidates.map { |_, s| s.subject }.uniq)
                          .index_by { |d| [ d.project_id, d.kind, d.subject ] }
        # NOT COMMITTED IS MATCHED WITHOUT ITS STATE: Home has no git digest to compare the stored one
        # with, so a dismissal holds while it is newer than the newest save (the header says why).
        candidates.reject { |row, s| TidyUp.dismissed?(dismissals[[ row.project.id, s.kind, s.subject ]], s, state: s.kind != "uncommitted") }
                  .map(&:first)
      end

      private

      # [Row, Suggestion] per repository with pending saves, in project-name order.
      def uncommitted_rows(pending)
        pending.filter_map do |root_id, (count, newest)|
          # STILL A REPOSITORY: a `.git` marker under the root, in memory over the tree. A folder whose
          # repository was removed keeps its pending rows until a commit page reconciles them, and a
          # Review link to a commit box that refuses would be a row nobody can act on.
          next unless tree.children_of(root_id).any? { |dir| Library::RepoMetadata.marker?(dir.name) }

          project = project_holding(root_id)
          next unless project

          name = root_id == project.folder_node_id ? project.name : tree.name_of(root_id)
          suggestion = Suggestion.new(kind: "uncommitted", subject: root_id, state: nil, since: newest, detail: nil)
          [ Row.new(kind: "uncommitted", project:, detail: Pending.new(root_node_id: root_id, name:, count:)), suggestion ]
        end.sort_by { |row, _| [ row.project.name.downcase, row.detail.name.to_s ] }
      end

      # [Row, Suggestion] per stale export, newest source edit first (the query's order).
      def export_rows(exports)
        exports.filter_map do |from_id, to_id, derived_name, source_name, source_mtime, derived_parent, source_parent|
          project = project_holding(derived_parent) || project_holding(source_parent)
          next unless project

          suggestion = Suggestion.new(kind: "export_older", subject: TidyUp.link_subject(from_id, to_id),
                                      state: source_mtime.to_s, detail: nil)
          detail = ExportOlder.new(derived_id: from_id, derived_name:, source_id: to_id, source_name:)
          [ Row.new(kind: "export_older", project:, detail:), suggestion ]
        end
      end

      # The project whose folder is `dir_id` or holds it, nearest first; nil outside every project.
      def project_holding(dir_id)
        return nil if dir_id.nil?

        tree.ancestors_of(dir_id)&.each do |id|
          project = projects_by_folder[id]
          return project if project
        end
        nil
      end

      def tree = @tree ||= Maker::LibraryTree.new(@user)

      def projects_by_folder
        @projects_by_folder ||= @user.maker_projects.where.not(status: "archived").where.not(folder_node_id: nil)
                                     .select(:id, :user_id, :name, :slug, :folder_node_id).index_by(&:folder_node_id)
      end
    end
  end
end
