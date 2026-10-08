# Pin and unpin a folder in the sidebar's Places (structural redesign spec §4.1). Session-authed
# web layer (§14d). Both answer with a redirect to the folder, so the maker sees the sidebar change
# where they are standing. `destroy` finds by node_id within current_user, so another user's pin
# is a 404, never a delete.
class PinsController < ApplicationController
  def create
    pin = current_user.maker_pins.new(node_id: params[:node_id].to_s)
    if pin.save
      redirect_to files_path(folder: pin.node_id), notice: "Pinned to the sidebar."
    else
      redirect_back fallback_location: files_path, alert: pin.errors.full_messages.to_sentence
    end
  end

  def destroy
    pin = current_user.maker_pins.find_by!(node_id: params[:id].to_s)
    pin.destroy!
    redirect_to files_path(folder: pin.node_id), notice: "Unpinned from the sidebar."
  end
end
