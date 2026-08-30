# Review pending edits in one repository, then commit the selected paths.
#
# SESSION-AUTHED, NEVER THE v1 API. §14d: /v1/* is device-token; the web app is cookies, and a
# web controller is not limited to what the JSON API exposes.
#
# THE TABLE IS A HINT, NOT AN AUTHORITY. Every pending row is re-asked of git here: the path is
# recomputed from the catalog, the row is dropped if the node is gone or has moved out of this
# repository or now matches HEAD, and it is listed-but-not-committable when .gitignore covers it.
class RepoCommitsController < ApplicationController
  # git's own binary test: a NUL byte within the first 8 kB of the file (see #binary_paths).
  BINARY_SNIFF_BYTES = 8_000

  before_action :load_repo

  # THREE GROUPS, AND ONLY THE FIRST IS CHECKED. The reconciled `maker_repo_edits` rows are what
  # tinkerex itself wrote and stay pre-checked exactly as they were; everything else git sees is
  # offered UNCHECKED, which is the whole of the safety property this feature deliberately reduced
  # (spec part 1). The box used to be structurally incapable of touching the maker's other work
  # because unedited paths were never listed; now the protection is "not by default, one click
  # away". Pre-checking either of the wider groups removes the reduction while every other test
  # here stays green, which is why the mutation is named in git-editing.md.
  #
  # `Library::OsClutter.ignore?` PARTITIONS, NEVER A SECOND LIST OF NAMES (§14b). That predicate is
  # composed once and consulted from both the observers and the write guards; a `%w[.DS_Store]`
  # here would be a third copy, free to disagree, and it would miss `._`-prefixed AppleDouble
  # sidecars entirely — the population a share library over SMB actually accumulates.
  def show
    @rows, @dropped = reconcile
    Maker::RepoEdit.where(user: current_user, node_id: @dropped).delete_all if @dropped.any?

    full = @local.full_status
    @truncated_count = full.truncated_count
    rest = full.rows.reject { |r| @rows.key?(r.path) }
    @clutter_rows, @other_rows = rest.partition { |r| Library::OsClutter.ignore?(r.path) }

    @node_id_by_path.merge!(catalog_node_ids(rest.map(&:path)))
    @binary_paths = binary_paths(@rows.values + rest)
    @head = @local.unborn? ? nil : @local.rugged.head.target_id
  end

  # THE INTERSECTION IS THE AUTHORITY, AND IT HAD TO WIDEN WITH THE BOX. `params[:paths]` is
  # whatever a browser posted; what may be committed is what the page could legitimately have
  # offered, so the submitted list is intersected with the committable rows of ALL THREE groups.
  #
  # THE PLAN SAID THIS METHOD NEEDED NO CHANGE. It did: the intersection was against `reconcile`
  # alone, which only ever knows the `maker_repo_edits` rows, so every path in "Other changes" and
  # "OS clutter" fell out of it and the commit answered "Nothing selected." — the new capability
  # silently doing nothing, on a redirect that looks exactly like the refusal path. That is why
  # step 3 says to verify by test rather than assume; "a path from Other changes commits, and only
  # it" is the case that found it.
  def create
    rows, = reconcile
    paths = Array(params[:paths]) & committable_paths(rows)

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
    root_path = repo_root_path
    pending = Maker::RepoEdit.pending_for(current_user, @root.node_id).to_a
    nodes = current_user.nodes.present.where(node_id: pending.map(&:node_id)).index_by(&:node_id)

    by_path, dropped = {}, []
    pending.each do |row|
      full = full_path_for(nodes[row.node_id])
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

  # Every path the box would have rendered a CHECKED-ABLE control for. Deliberately recomputed
  # rather than trusted from the form: a hidden field listing them would be the client telling the
  # server what it is allowed to commit.
  def committable_paths(rows)
    rows.select { |_, r| r.committable? }.keys | @local.full_status.rows.select(&:committable?).map(&:path)
  end

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

  # Which listed paths cannot be diffed, by CONTENT — git's own rule, a NUL byte in the first 8 kB.
  #
  # DELIBERATELY NOT `Maker::FileAttachment.text?`, AND THIS IS NOT THE SECOND-VOCABULARY MISTAKE
  # §14d warns about. That predicate answers a NAME question — "should the file page offer a source
  # viewer" — off an extension allowlist, and it answers FALSE for `.svg`. The measured repository
  # this whole feature exists for (`catan`, spec part 1) is 58 dirty paths of which the design files
  # are `.svg`, so the name-based answer would print "binary — no diff" over every one of them. The
  # question here is whether CodeMirror can be handed these bytes, which is a CONTENT axis —
  # files-preview.md's own distinction — and answering it the way git does keeps the panel and the
  # terminal saying the same thing. Adding `.svg` to `ROLE_BY_EXT` is still the fix for the file
  # page; it is not the fix for this.
  def binary_paths(rows)
    rows.each_with_object(Set.new) do |row, out|
      next unless row.state == :modified || row.state == :added || row.state == :ignored

      begin
        sniff = File.binread(File.join(@local.workdir, row.path), BINARY_SNIFF_BYTES)
      rescue SystemCallError
        next
      end
      out << row.path if sniff&.include?("\x00".b)
    end
  end

  def node_ids_for(paths) = paths.filter_map { |p| @node_id_by_path[p] }
end
