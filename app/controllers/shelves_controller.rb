# Which library folders are SHELVES -- folders that are not themselves models. Session-authed web
# layer (§14d), not the device-token v1 API. Reads `nodes` and writes only maker_shelves rows; no
# bytes and no port calls, so there is nothing to capability-gate.
class ShelvesController < ApplicationController
  def index
    Maker::Shelf.seed_once!(current_user)
    @tree = Maker::LibraryTree.new(current_user)
    @shelves = current_user.maker_shelves.order(:path).map { |shelf| decorate(shelf) }
  end

  # THE CHOOSER POSTS A node_id AND THIS DERIVES THE PATH. A folder picker cannot produce a path
  # string, and deriving it here is the only place the picked node and the stored pattern can be
  # kept in step. The node is resolved through current_user, so a foreign id resolves to nothing.
  def create
    path = path_for_param(params[:node_id])
    return redirect_to(shelves_path, alert: "That folder isn't in your library.") if path.nil?

    shelf = current_user.maker_shelves.new(path:)
    return redirect_to(shelves_path, notice: "#{display(path)} is now a shelf.") if shelf.save

    # THE MODEL'S OWN MESSAGE, NOT A GUESSED ONE. Two different validations can refuse this row --
    # uniqueness, and the reserved/traversal segment check -- and a picker CAN reach the second: a
    # library with a real `.trash` directory in it offers that folder like any other. Assuming
    # "already a shelf" here would tell a user the wrong fact about their own library, which is the
    # shape §14a records for a clobber answered as "File not found."
    redirect_to shelves_path, alert: "#{display(path)} #{shelf.errors[:path].first || 'could not be added'}."
  end

  def destroy
    shelf = current_user.maker_shelves.find(params[:id])
    shelf.destroy!
    redirect_to shelves_path, notice: "#{display(shelf.path)} is no longer a shelf."
  end

  private

  # "" for the library root -- the chooser sends a blank node_id for it, and a blank id must not
  # resolve to "some folder"; it is the root, deliberately.
  def path_for_param(node_id)
    return "" if node_id.blank?

    # SCOPED, AND NO TEST CAN SEE IT -- said plainly so the next reader who mutation-checks this
    # line does not read GREEN as "dead scope, delete it". The tenancy is enforced TWICE: swapping
    # `current_user.nodes` for `Node` still refuses a foreign id, because the tree below is built
    # from current_user and answers nil for a node_id it does not hold. Measured: the whole suite
    # stays green with the scope removed. It stays because a lookup that is right by ACCIDENT of a
    # collaborator's scoping is one refactor away from being wrong.
    node = current_user.nodes.present.find_by(node_id:, kind: "dir")
    return nil unless node

    Maker::LibraryTree.new(current_user).path_for(node.node_id)
  end

  # WHAT MAKES PATH-KEYING HONEST. A stored pattern is not a live folder, so the page says whether
  # it currently names one -- and a wildcard says how many. Without this a renamed folder silently
  # stops being a shelf and the catalog quietly changes shape.
  def decorate(shelf)
    # THE MEMO IS LOAD-BEARING, not a micro-optimisation: this runs once per shelf inside `#index`'s
    # `map`, so without it the page costs one pluck PER SHELF. Guarded by
    # page_query_budget_test.rb ("shelves#index does not grow"). Measured: 5 queries flat with the
    # memo at both 3 and 15 shelves, 7 -> 19 across that same range without it.
    matches = @tree_paths ||= begin
      ids = current_user.nodes.present.where(kind: "dir").pluck(:node_id)
      ids.filter_map { |id| @tree.path_for(id) } << ""
    end
    hits = matches.count { |path| Maker::Shelf.matches?(shelf.path, path) }
    { record: shelf, label: display(shelf.path), wildcard: shelf.path.include?("*"), hits: }
  end

  def display(path) = path.presence || "/ (library root)"
end
