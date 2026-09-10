module Files
  # CREATE AN EMPTY TEXT FILE IN THE FOLDER THE USER IS LOOKING AT, then hand them the editor
  # (2026-09-10). The bytes go through the port like every other write (§15) — this writes "" rather
  # than touching the store directly, so share's temp-and-rename and s3's put_object both apply, and
  # `Maker::TextSave` carries the clobber refusal, the preview enqueue and the node-reuse rule with
  # it.
  #
  # `repo_root_node_id:` IS NOT PASSED, AND THAT IS THE WHOLE BRANCH THIS DOOR DOES NOT HAVE.
  # Maker::TextSave records a pending git edit only when a repo root is NAMED and the backend holds
  # the working tree, so a file created outside a repository simply gets none — no `if` anywhere,
  # and a create inside one keeps its behaviour if this door ever learns to name a root.
  class TextFilesController < ApplicationController
    def new
      @parent_node_id = params[:parent_node_id].presence
    end

    def create
      @parent_node_id = params[:parent_node_id].presence
      name = params[:name].to_s.strip
      # TWO QUESTIONS IN THE SAME BREATH (§14b). `valid_leaf_name?` answers syntax; `reserved?`
      # answers the library's own namespace (.trash, .maker-tmp-*, .git, OS clutter). The upload
      # door shipped asking NEITHER and minted a live node named "../../escape.txt".
      unless Maker::MoveNode.valid_leaf_name?(name) && !Library::ReservedNames.reserved?(name)
        return refuse(:unprocessable_entity,
                      "#{name.presence || "That"} is not a name this library can use.")
      end

      result = Maker::TextSave.call(user: current_user, node: nil, parent_node_id: @parent_node_id,
                                    name:, body: "", base_token: nil, repo_root_node_id: nil)
      return refuse(result.status, result.error) unless result.ok

      redirect_to file_path(result.node_id), notice: "Created #{name}."
    rescue FileLayer::UnsupportedOperation => e
      # THE CLOBBER REFUSAL, WHICH Maker::TextSave RAISES TO ITS CALLER UNCHANGED (its own header
      # says so): a name already taken here is this door's sentence to word, not the service's.
      # Un-rescued it is a 500 on an ordinary typo.
      refuse(:unprocessable_entity, e.message)
    rescue FileLayer::FetchError => e
      # §14a maps FetchError once, at the door: an unmounted share is retryable, not "your file is
      # gone". FilesController#update carries the identical arm.
      refuse(:service_unavailable, e.message)
    rescue FileLayer::NotFound
      # THE PARENT WENT AWAY BETWEEN OPENING THE FORM AND SUBMITTING IT, and this arm is NOT
      # theoretical: `parent_node_id` rides as a hidden field, so another tab's Delete, a device
      # push plus changelog pull, or an ordinary scan reconcile is enough. Driven, not reasoned —
      # without this the exception escapes the request entirely (`FileLayer::NotFound: parent
      # "<uuid>" is not a live directory`) and the maker gets a 500 with their typed name lost.
      #
      # IT NEEDS ITS OWN ARM BECAUSE `NotFound` IS A SIBLING, NOT A SUBCLASS, of the two above
      # (`Class.new(StandardError)` each, file_layer.rb:10-17), and this controller does NOT inherit
      # FilesController's `rescue_from` — ApplicationController has none at all. Every future door
      # outside FilesController that touches the port has the same hole.
      #
      # The message is the DOOR's, not the port's: the port names a node id, which is not a sentence
      # to show a maker (the same reason the folder menu is gated rather than left to flash one).
      refuse(:not_found, "That folder is no longer here. It may have been moved or deleted.")
    end

    private

    # `flash.now`, NOT `render ..., alert:`. `render` has no `:alert` option — it is silently
    # dropped, so the refusal would answer the right status with nothing on the page saying why.
    def refuse(status, message)
      flash.now[:alert] = message
      render :new, status:
    end
  end
end
