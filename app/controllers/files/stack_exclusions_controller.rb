module Files
  # PULL ONE FILE OUT OF ITS VERSION STACK, AND PUT IT BACK (Shop manual spec §9: "a way to pull one
  # file out"). Session-authed and current_user-scoped like the other per-file doors beside it
  # (Files::LinksController, Files::PreviewsController); the row itself is Maker::StackExclusion,
  # keyed by node_id so a pulled-out file stays out through a rename or a move (§14b).
  #
  # BOTH ANSWERS GO BACK TO THE PAGE THE BUTTON WAS ON — the Library, a project panel, Search — so
  # the maker sees the file standing alone (or back in its stack) where they pressed. A Turbo form
  # follows the redirect, so the page redraws with the notice and nothing else changes.
  #
  # BOTH ARE IDEMPOTENT, as the model's two verbs are: a second Pull out answers the row the first
  # made, and Put back on a file never pulled out removes nothing. Neither is an error to report.
  class StackExclusionsController < ApplicationController
    # POST /files/:node_id/stack_exclusion
    def create
      node = live_file
      return refuse if node.nil?

      Maker::StackExclusion.pull_out!(current_user, node.node_id)
      redirect_back_or_to file_path(node.node_id), notice: "Pulled #{node.name} out of its stack."
    end

    # DELETE /files/:node_id/stack_exclusion
    def destroy
      node = live_file
      return refuse if node.nil?

      Maker::StackExclusion.put_back!(current_user, node.node_id)
      redirect_back_or_to file_path(node.node_id), notice: "Put #{node.name} back in its stack."
    end

    private

    # A LIVE FILE OF THIS USER, or nil: another user's node, a folder, a tombstone and a bogus id
    # are all "not in your library" (the model's own validation, asked first so the answer is a
    # sentence rather than a RecordInvalid).
    def live_file = current_user.nodes.present.find_by(node_id: params.require(:node_id).to_s, kind: "file")

    def refuse = redirect_back_or_to(files_path, alert: "That file isn't in your library.")
  end
end
