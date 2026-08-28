module Library
  # Is this node inside a git working tree, and if so where does that tree START?
  #
  # MOVED OUT OF Maker::AttachToProject, NOT COPIED. That class asked a boolean
  # (`in_working_tree?`) and the git editing surface needs the ROOT NODE, so keeping both would be
  # one question with two implementations -- the drift §14d names a service to end. AttachToProject
  # now asks this and compares against nil; its rules came with the walk and are restated below
  # because they are load-bearing, not decoration.
  #
  # THE ROOT IS THE MARKER'S PARENT. `Library::RepoMetadata` keeps the `.git` directory node
  # indexed precisely so this question is answerable, on all three backends -- on chunk_remote the
  # mirror carries whatever the desktop client synced, and app/services/library/repo_metadata_purge.rb
  # records as a decision that those rows are HIDDEN rather than removed.
  #
  # `present` AND `kind: "dir"` ARE BOTH LOAD-BEARING. A tombstoned `.git` is not a working tree --
  # without the scope, deleting a repository would freeze its former folder against
  # Maker::ProjectIntake's sweep forever with nothing visible saying why. And a `.git` FILE is a
  # submodule's or a linked worktree's `gitdir:` pointer; nothing here reads the pointer, so
  # treating it as a marker would be right by accident and wrong by construction.
  #
  # MEMOISED ON THE PARENT, NOT ON THE NODE. Maker::ProjectIntake sweeps every file at one project
  # folder's root through this, so without the memo the walk runs once per FILE at two queries per
  # level. The memo lives on the instance and the instance lives for one sweep or one request, so
  # there is no staleness window worth naming.
  class WorkingTree
    # A cap on the ancestor walk. Not defensive dressing: `parent_node_id` is a plain string column
    # with no foreign key, so a cycle is representable and an uncapped `while` here is an infinite
    # loop in a request.
    MAX_ANCESTOR_WALK = 64

    def initialize(user)
      @user = user
      @roots = {}
    end

    # The repository ROOT node for `node`, or nil. A node that IS the marker resolves to its
    # parent, which is what makes `root_for` total over every node in a repository.
    def root_for(node)
      parent_id = node.parent_node_id
      return nil if parent_id.nil?
      return @roots[parent_id] if @roots.key?(parent_id)

      @roots[parent_id] = walk_for_root(parent_id)
    end

    def in_working_tree?(node) = !root_for(node).nil?

    private

    def walk_for_root(parent_id)
      id = parent_id
      MAX_ANCESTOR_WALK.times do
        break if id.nil?

        if @user.nodes.present.exists?(parent_node_id: id, kind: "dir",
                                       name: Library::RepoMetadata::DIR_NAME)
          return @user.nodes.present.find_by(node_id: id)
        end

        id = @user.nodes.where(node_id: id).pick(:parent_node_id)
      end
      nil
    end
  end
end
