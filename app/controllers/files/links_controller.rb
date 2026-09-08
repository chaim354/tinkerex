module Files
  # The two hand-set file links (stage 4, S4-8): "This came from …" and "Add a photo of this".
  # Session-authed and current_user-scoped, like NotesController, which this is modelled on.
  #
  # ONE ACTION FOR BOTH KINDS, AND THE DIRECTION IS DECIDED HERE. The URL's node is the SUBJECT —
  # the page you are standing on — and `kind` says which end of the pair that is: a `derived_from`
  # subject is the DERIVED file, a `photo_of` subject is the file being DEPICTED. Letting the form
  # post `from`/`to` directly would let one control write a link the other control's page then
  # renders backwards, and no server-side test could tell an inverted link from a correct one.
  #
  # OWNERSHIP IS THIS DOOR'S QUESTION, NOT THE MODEL'S (Maker::FileLink's own comment): both nodes
  # are resolved through `current_user.nodes.present` before anything is written, and a node
  # belonging to someone else simply is not found. LIVENESS IS A READ-TIME QUESTION (§14a), so
  # `.present` here is what refuses a link INTO a tombstone; a link whose end dies afterwards is
  # dropped by the page and destroyed later by Maker::AttachmentReaper.
  class LinksController < ApplicationController
    # POST /files/:node_id/links { kind, other_node_id }
    def create
      subject = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      return refuse(files_path, "That file isn't in your library.") if subject.nil?

      kind = params[:kind].to_s
      return refuse(file_path(subject.node_id), "That isn't a kind of link.") unless
        Maker::FileLink::KINDS.include?(kind)

      other = current_user.nodes.present.find_by(node_id: params[:other_node_id].to_s, kind: "file")
      return refuse(file_path(subject.node_id), "Pick a file in your library.") if other.nil?
      # THE PICKER'S FILTER IS A CONVENIENCE; THIS IS THE REFUSAL. lib/file_chooser.js says so in as
      # many words about `extensions` — it is a courtesy to the human picking and never a
      # restriction — so the vocabulary question is asked again here, through the one definition.
      return refuse(file_path(subject.node_id), "Only an image can be a photo of a file.") if
        kind == "photo_of" && Maker::FileAttachment.role_for(other.name) != "image"

      from, to = kind == "photo_of" ? [ other.node_id, subject.node_id ]
                                    : [ subject.node_id, other.node_id ]
      link = current_user.maker_file_links.new(from_node_id: from, to_node_id: to, kind:)
      return refuse(file_path(subject.node_id), link.errors.full_messages.to_sentence) unless link.save

      respond_to do |f|
        f.html { redirect_to file_path(subject.node_id), notice: "Linked #{other.name}." }
        f.json { render json: { id: link.id }, status: :created }
      end
    rescue ActiveRecord::RecordNotUnique
      # ALREADY LINKED IS THIS REQUEST'S INTENT ALREADY SATISFIED, not an error to surface — the
      # argument Projects::EntryPhotosController#create carries for maker_file_attachments'
      # unique index, and the reason there is no `validates :uniqueness` on the model (a second
      # SELECT on every write that would still lose the race a double-click creates).
      respond_to do |f|
        f.html { redirect_to file_path(params[:node_id]), notice: "Already linked." }
        f.json { head :ok }
      end
    end

    # DELETE /file_links/:id
    def destroy
      link = current_user.maker_file_links.find(params[:id])
      # BACK TO THE PAGE THE REMOVE BUTTON WAS ON, which is either end of the pair. `back_target_path`
      # is not reachable here (the button posts, so there is no meaningful referer chain for it);
      # the subject travels as a param the view already knows.
      node_id = current_user.nodes.present.exists?(node_id: params[:from]) ? params[:from] : link.from_node_id
      link.destroy!
      redirect_to file_path(node_id), notice: "Link removed."
    end

    private

    def refuse(path, message)
      respond_to do |f|
        f.html { redirect_to path, alert: message }
        f.json { render json: { error: message }, status: :unprocessable_entity }
      end
    end
  end
end
