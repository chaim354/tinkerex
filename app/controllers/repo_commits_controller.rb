# Review pending edits in one repository, then commit the selected paths.
#
# SESSION-AUTHED, NEVER THE v1 API. §14d: /v1/* is device-token; the web app is cookies, and a
# web controller is not limited to what the JSON API exposes.
#
# THE TABLE IS A HINT, NOT AN AUTHORITY. Every pending row is re-asked of git here: the path is
# recomputed from the catalog, the row is dropped if the node is gone or has moved out of this
# repository or now matches HEAD, and it is listed-but-not-committable when .gitignore covers it.
class RepoCommitsController < ApplicationController
  before_action :load_repo

  # WHAT THE BOX OFFERS, AS ONE VALUE, BUILT ONCE PER REQUEST BY #reconcile AND READ BY BOTH
  # ACTIONS: the three groups of LocalRepo::Row, the pending rows' node ids, the maker_repo_edits
  # rows to drop, and how many changed paths the cap left out.
  #
  # `offered_paths` IS #create's AUTHORITY, AND IT COMES FROM THE ROWS THE PAGE RENDERS. The view
  # draws a checkbox exactly where a row is committable; #create accepts exactly the committable
  # rows of all three groups. Computing that list a second time is a second definition of "what the
  # page offered", free to disagree with the first, and #create's comment records the time it did.
  Staging = Data.define(:pending, :other, :clutter, :pending_node_ids, :dropped, :truncated_count) do
    def offered_paths = (pending + other + clutter).select(&:committable?).map(&:path)
  end

  # THREE GROUPS, AND ONLY THE FIRST IS CHECKED. The reconciled `maker_repo_edits` rows are what
  # tinkerex itself wrote and stay pre-checked exactly as they were; everything else git sees is
  # offered UNCHECKED, which is the whole of the safety property this feature deliberately reduced
  # (spec part 1). The box used to be structurally incapable of touching the maker's other work
  # because unedited paths were never listed; now the protection is "not by default, one click
  # away". Pre-checking either of the wider groups removes the reduction while every other test
  # here stays green, which is why the mutation is named in git-editing.md. The `checked:` values
  # live in the VIEW, beside the markup they decide, and stay there.
  #
  # `Library::OsClutter.ignore?` PARTITIONS, NEVER A SECOND LIST OF NAMES (§14b). That predicate is
  # composed once and consulted from both the observers and the write guards; a `%w[.DS_Store]`
  # here would be a third copy, free to disagree, and it would miss `._`-prefixed AppleDouble
  # sidecars entirely — the population a share library over SMB actually accumulates.
  def show
    @staging = reconcile
    Maker::RepoEdit.where(user: current_user, node_id: @staging.dropped).delete_all if @staging.dropped.any?

    wider = @staging.other + @staging.clutter
    @diff_node_ids = @staging.pending_node_ids.merge(catalog_node_ids(wider.map(&:path)))
    @head = @local.unborn? ? nil : @local.rugged.head.target_id
  end

  # THE INTERSECTION IS THE AUTHORITY, AND IT HAD TO WIDEN WITH THE BOX. `params[:paths]` is
  # whatever a browser posted; what may be committed is what the page could legitimately have
  # offered, so the submitted list is intersected with `offered_paths`: the committable rows of ALL
  # THREE groups, recomputed here rather than trusted from the form (a hidden field listing them
  # would be the client telling the server what it is allowed to commit).
  #
  # THE PLAN SAID THIS METHOD NEEDED NO CHANGE. It did: the intersection was against `reconcile`
  # alone, which then knew only the `maker_repo_edits` rows, so every path in "Other changes" and
  # "OS clutter" fell out of it and the commit answered "Nothing selected." — the new capability
  # silently doing nothing, on a redirect that looks exactly like the refusal path. That is why
  # step 3 says to verify by test rather than assume; "a path from Other changes commits, and only
  # it" is the case that found it. It is also why the list is now READ OFF the Staging the page
  # renders from instead of being assembled a second time beside it.
  def create
    staging = reconcile
    paths = Array(params[:paths]) & staging.offered_paths

    Maker::Git::CommitPaths.new(@local).call(paths:, message: params[:message].to_s,
                                             expected_head: params[:expected_head].presence)
    Maker::RepoEdit.where(user: current_user, node_id: staging.pending_node_ids.slice(*paths).values).delete_all
    redirect_to repo_commit_path(@root.node_id), notice: "Committed #{paths.size} file(s)."
  rescue Maker::Git::CommitPaths::RefMoved
    redirect_to repo_commit_path(@root.node_id),
                alert: "Another commit landed while you were reviewing. Here is the current state."
  rescue Maker::Git::CommitPaths::NothingToCommit
    redirect_to repo_commit_path(@root.node_id), alert: "Nothing selected."
  end

  # HEAD's version of one path, as text, for the browser to diff against the working tree. The
  # server ships two blobs and diffs neither — that is what deletes the server-side text diff
  # tinkerex#161 built (spec part 13).
  #
  # REJECTS, NEVER NORMALIZES, on §14b's rule for `key_for`. A `..` segment cannot escape a git
  # TREE (probed: `Rugged::TreeError: the path '..' does not exist in the given tree`), so this is
  # not the disclosure guard it looks like — it is the guard against `File.file?` below being
  # asked about somewhere outside the workdir. The real defect it closes is the DIRECTORY case:
  # `head_text_for("src")` looks up a tree and calls `.content` on it, which is
  # `NoMethodError: undefined method 'content' for an instance of Rugged::Tree` — a 500 off a
  # user-supplied param. Probed, not reasoned; the plan's version has it.
  def head_blob
    rel = params[:path].to_s
    return head :bad_request unless safe_relative?(rel) && File.file?(File.join(@local.workdir, rel))

    render plain: @local.head_text_for(rel), content_type: "text/plain"
  end

  private

  def load_repo
    @root = current_user.nodes.present.find_by!(node_id: params[:root_id], kind: "dir")
    @local = Maker::Git::LocalRepo.open(current_user, @root)
    return if @local.committable?

    redirect_to files_path, alert: @local.refusal
  end

  def safe_relative?(rel)
    rel.present? && !rel.start_with?("/") && rel.split("/").none? { |s| s == ".." || s.empty? }
  end

  # THE STAGING, BUILT ONCE PER REQUEST. Every row is a content read compared against HEAD's blob
  # (LocalRepo#row_for, ~15 ms per object over CIFS), so each path's row is computed ONCE: a pending
  # path that git status lists takes its row from full_status, and only the pending paths
  # full_status did not reach are asked about by name (`.gitignore`d and untracked, past the cap,
  # matching HEAD, or gone). A pending row and its full_status twin are therefore one row read at
  # one moment, never two reads that can disagree.
  #
  # A pending row is DROPPED when the catalog no longer places its node in this repository, or when
  # git says there is nothing to commit for it: :unchanged (it matches HEAD again) or :missing (in
  # neither HEAD nor the working tree). The other two groups are every listed row not kept as
  # pending, split by Library::OsClutter.
  def reconcile
    @staging ||= begin
      node_ids, gone = pending_paths
      full   = @local.full_status
      listed = full.rows.index_by(&:path)
      asked  = @local.status_for(node_ids.keys - listed.keys)

      pending, stale = node_ids.keys.map { |rel| listed[rel] || asked.fetch(rel) }
                                    .partition { |row| row.state != :unchanged && row.state != :missing }
      kept = pending.map(&:path).to_set
      clutter, other = full.rows.reject { |row| kept.include?(row.path) }
                                .partition { |row| Library::OsClutter.ignore?(row.path) }

      Staging.new(pending:, other:, clutter:, pending_node_ids: node_ids.slice(*kept),
                  dropped: gone + stale.map { |row| node_ids.fetch(row.path) },
                  truncated_count: full.truncated_count)
    end
  end

  # Returns [rel => node_id, node_ids_to_drop] for this repository's pending rows. The path comes
  # from the catalog every time — the table stores none, so it cannot disagree with the library
  # after a node moves.
  #
  # `Maker::LibraryTree` INDEXES DIRECTORIES ONLY, so a pending row's own node id resolves to nil
  # there and the plan's `tree.path_for(row.node_id)` would drop EVERY row — an always-empty
  # commit box, on a page whose emptiness reads as "nothing to commit". The tree answers about the
  # PARENT (files_controller.rb:1169 is the same call), and the file's own name is appended. A row
  # whose node is gone or tombstoned has no Node here at all and is dropped, which is the same
  # answer by a shorter route.
  def pending_paths
    root_path = repo_root_path
    pending = Maker::RepoEdit.pending_for(current_user, @root.node_id).to_a
    nodes = current_user.nodes.present.where(node_id: pending.map(&:node_id)).index_by(&:node_id)

    by_path, gone = {}, []
    pending.each do |row|
      full = full_path_for(nodes[row.node_id])
      rel  = full && root_path && full.start_with?("#{root_path}/") ? full.delete_prefix("#{root_path}/") : nil
      next gone << row.node_id if rel.nil?

      by_path[rel] = row.node_id
    end
    [ by_path, gone ]
  end

  def full_path_for(node)
    return nil if node.nil?

    parent = tree.path_for(node.parent_node_id)
    parent.blank? ? nil : "#{parent}/#{node.name}"
  end

  # ONE tree and one root path per request. `Maker::LibraryTree` costs a pluck of every live dir,
  # and #show asks it twice now — once to place the pending rows, once to resolve the wider list's
  # nodes — so building it twice would double that pluck for one unchanged answer.
  def tree = @tree ||= Maker::LibraryTree.new(current_user)

  def repo_root_path = @repo_root_path ||= tree.path_for(@root.node_id)

  # The live catalog node for each repo-relative path, so the browser can fetch the WORKING TREE
  # side of the diff (the other side is HEAD's blob, which needs no node). ONE query for the whole
  # page: the parent directory ids come from the tree already built for `reconcile`, so this does
  # not grow with the number of rows.
  #
  # A PATH WITH NO NODE IS NORMAL, NOT AN ERROR — `Library::Scanner` skips OS clutter and the
  # `.git` interior, and a `:deleted` path's node is tombstoned. Those rows are still listed and
  # still committable; they simply mount no diff, which the view decides.
  def catalog_node_ids(rels)
    return {} if rels.empty? || repo_root_path.blank?

    dir_ids = tree.dir_ids.each_with_object({}) do |id, out|
      path = tree.path_for(id)
      out[path] = id if path
    end
    wanted = rels.to_h do |rel|
      dir = File.dirname(rel)
      [ rel, [ dir_ids[dir == "." ? repo_root_path : "#{repo_root_path}/#{dir}"], File.basename(rel) ] ]
    end
    lookup_nodes(wanted)
  end

  def lookup_nodes(wanted)
    keys = wanted.values.reject { |parent_id, _| parent_id.nil? }
    return {} if keys.empty?

    found = current_user.nodes.present
                        .where(kind: "file", parent_node_id: keys.map(&:first).uniq,
                               name: keys.map(&:last).uniq)
                        .pluck(:parent_node_id, :name, :node_id)
                        .to_h { |parent_id, name, id| [ [ parent_id, name ], id ] }
    wanted.filter_map { |rel, key| [ rel, found[key] ] if found[key] }.to_h
  end
end
