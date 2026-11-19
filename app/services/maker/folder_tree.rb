module Maker
  # THE LIBRARY COLUMN'S FOLDER TREE (Shop manual spec §9): the folders under one folder (the library
  # root, for the column's first paint), with every folder the tree holds OPEN listed beneath it, as
  # nested Branches. Read by ShellHelper for the column (layouts/column/_library) and by
  # LibraryBrowseController#tree for one folder opened in place.
  #
  # WHICH FOLDERS ARE OPEN. The chain down to the folder on screen (FilesController's `@crumbs`),
  # always, so the first paint shows where the page is with each level's siblings; and the folders the
  # maker opened, which the column remembers in the `library_tree` cookie (column_tree_controller.js
  # writes it; design-system.md rule 7, the theme cookie's shape). The server trusts nothing in that
  # cookie beyond WELL-FORMED ids (`ID`), the newest `OPEN_MAX` of them, and it opens one only where
  # the tree reaches it: a folder is drawn only as the child of a folder already drawn, so an id that
  # names a tombstone, someone else's folder, a hidden folder or nothing at all opens nothing.
  #
  # TWO QUERIES WHATEVER IT HOLDS, never one per folder or per open folder (page_query_budget_test.rb):
  #   1. every open folder's subfolders at once, ranked within their folder (ROW_NUMBER, which SQLite
  #      and Postgres both have; Maker::ProjectFolderListing's precedent) and cut at CAP + 1, so a
  #      folder of ten thousand subfolders costs what one of forty does and the extra row says the
  #      list was cut;
  #   2. which of the folders drawn CLOSED have subfolders of their own, so only those get a
  #      disclosure.
  # The same rows the Library lists: live, visible (`visible_entries`: no dot-folders, no `.git`, no
  # build output, §14b), from `nodes`, the catalog all three backends populate. No counts: a total
  # beside each folder is a walk of its whole subtree, and the root's subtree is the library, on every
  # Library page.
  class FolderTree
    # Subfolders listed under one folder before "All folders here" (ShellHelper::COLUMN_FOLDERS).
    CAP = 40
    COOKIE = "library_tree".freeze
    # The newest open folders the cookie keeps (column_tree_controller.js drops the oldest past it).
    OPEN_MAX = 50
    # A node id the cookie may name: the uuids all three backends mint, and the short ids tests use.
    # Anything else is dropped rather than looked up; the separator below cannot occur in one.
    ID = /\A[A-Za-z0-9_-]{1,64}\z/
    SEPARATOR = ".".freeze

    # `children` is the folder's own Branches when it is drawn open, nil when closed. `expandable` says
    # it has subfolders (so it gets a disclosure); `more` that its list was cut at CAP.
    Branch = Data.define(:node_id, :name, :depth, :children, :expandable, :more) do
      def open? = !children.nil?
    end

    def self.open_ids(cookie)
      return [] unless cookie.is_a?(String)

      cookie.split(SEPARATOR).grep(ID).uniq.last(OPEN_MAX)
    end

    # `root_id` nil is the library root. `depth` is the depth of the root's children (the column draws
    # the root itself at 0). `chain` is the Nodes from the root down to the folder on screen.
    def initialize(user, open_ids:, root_id: nil, depth: 1, chain: [])
      @user = user
      @root_id = root_id
      @depth = depth
      @chain = chain
      @open = Set.new(chain.map(&:node_id)) | open_ids
      load_children
      keep_chain
      @has_subfolders = subfolder_parents(closed_ids)
    end

    # The root's subfolders, each open one carrying its own.
    def branches
      @branches ||= build(@root_id, @depth, Set.new)
    end

    # The root's own list was cut at CAP.
    def more? = @more.include?(@root_id)

    private

    # QUERY 1. Every open folder's subfolders, and the root's, ranked and cut per folder.
    def load_children
      parents = [ @root_id, *@open ].uniq
      ranked = dirs.where(parent_node_id: parents)
                   .select("nodes.node_id, nodes.parent_node_id, nodes.name, ROW_NUMBER() OVER " \
                           "(PARTITION BY nodes.parent_node_id ORDER BY LOWER(nodes.name), nodes.node_id) AS rank_in_dir")
      rows = Node.from(ranked, :nodes).where(Node.arel_table[:rank_in_dir].lteq(CAP + 1))
                 .pluck(:node_id, :parent_node_id, :name, Arel.sql("rank_in_dir"))
      @more = Set.new
      @children = rows.group_by { |row| row[1] }.to_h do |parent, kids|
        kids = kids.sort_by(&:last)
        @more << parent if kids.size > CAP
        [ parent, kids.first(CAP).map { |id, _, name| [ id, name ] } ]
      end
    end

    # THE FOLDER ON SCREEN IS ALWAYS DRAWN, AND SO IS EVERY FOLDER ABOVE IT, even where the list cut
    # it (the 45th of its folder's subfolders) or hides it (a dot-folder reached with hidden files
    # shown): the tree shows where the page is, and the lit row is that folder (rule 8). Each is
    # placed under the one above it in the chain, which is what the breadcrumb shows too.
    def keep_chain
      parent = @root_id
      @chain.each do |crumb|
        kids = (@children[parent] ||= [])
        kids << [ crumb.node_id, crumb.name ] unless kids.any? { |id, _| id == crumb.node_id }
        parent = crumb.node_id
      end
    end

    # The folders the tree draws closed: reached from the root through open folders only.
    def closed_ids
      ids = []
      walk(@root_id, Set.new) { |id, open| ids << id unless open }
      ids
    end

    # QUERY 2. Which of those have a visible subfolder (one query for all of them, or none for none).
    def subfolder_parents(ids)
      return Set.new if ids.empty?

      Set.new(dirs.where(parent_node_id: ids).distinct.pluck(:parent_node_id))
    end

    def dirs = @user.nodes.present.visible_entries(false).where(kind: "dir")

    # Depth-first from `parent` through open folders. `seen` stops a corrupt parent chain from
    # drawing one folder twice or looping.
    def walk(parent, seen, &block)
      @children.fetch(parent, []).each do |id, _name|
        next unless seen.add?(id)

        open = @open.include?(id)
        block.call(id, open)
        walk(id, seen, &block) if open
      end
    end

    def build(parent, depth, seen)
      @children.fetch(parent, []).filter_map do |id, name|
        next unless seen.add?(id)

        if @open.include?(id)
          kids = build(id, depth + 1, seen)
          Branch.new(node_id: id, name:, depth:, children: kids, expandable: kids.any?, more: @more.include?(id))
        else
          Branch.new(node_id: id, name:, depth:, children: nil, expandable: @has_subfolders.include?(id), more: false)
        end
      end
    end
  end
end
