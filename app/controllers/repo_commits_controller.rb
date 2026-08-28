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

  def show
    @rows, @dropped = reconcile
    Maker::RepoEdit.where(user: current_user, node_id: @dropped).delete_all if @dropped.any?
    @other_dirty = @local.other_dirty_count(@rows.keys)
    @head = @local.unborn? ? nil : @local.rugged.head.target_id
  end

  def create
    rows, = reconcile
    paths = Array(params[:paths]) & rows.select { |_, r| r.committable? }.keys

    Maker::Git::CommitPaths.new(@local).call(paths:, message: params[:message].to_s,
                                             expected_head: params[:expected_head].presence)
    Maker::RepoEdit.where(user: current_user, node_id: node_ids_for(paths)).delete_all
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

  # Returns [rows_by_path, node_ids_to_drop]. The path comes from the catalog every time — the
  # table stores none, so it cannot disagree with the library after a node moves.
  #
  # `Maker::LibraryTree` INDEXES DIRECTORIES ONLY, so a pending row's own node id resolves to nil
  # there and the plan's `tree.path_for(row.node_id)` would drop EVERY row — an always-empty
  # commit box, on a page whose emptiness reads as "nothing to commit". The tree answers about the
  # PARENT (files_controller.rb:1169 is the same call), and the file's own name is appended. A row
  # whose node is gone or tombstoned has no Node here at all and is dropped, which is the same
  # answer by a shorter route.
  def reconcile
    tree = Maker::LibraryTree.new(current_user)
    root_path = tree.path_for(@root.node_id)
    pending = Maker::RepoEdit.pending_for(current_user, @root.node_id).to_a
    nodes = current_user.nodes.present.where(node_id: pending.map(&:node_id)).index_by(&:node_id)

    by_path, dropped = {}, []
    pending.each do |row|
      full = full_path_for(tree, nodes[row.node_id])
      rel  = full && root_path && full.start_with?("#{root_path}/") ? full.delete_prefix("#{root_path}/") : nil
      next dropped << row.node_id if rel.nil?

      by_path[rel] = row.node_id
    end

    status = @local.status_for(by_path.keys)
    keep = {}
    status.each do |rel, r|
      if r.state == :unchanged || r.state == :missing
        dropped << by_path[rel]
      else
        keep[rel] = r
      end
    end
    @node_id_by_path = by_path
    [ keep, dropped ]
  end

  def full_path_for(tree, node)
    return nil if node.nil?

    parent = tree.path_for(node.parent_node_id)
    parent.blank? ? nil : "#{parent}/#{node.name}"
  end

  def node_ids_for(paths) = paths.filter_map { |p| @node_id_by_path[p] }
end
