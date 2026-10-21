# WHICH FOLDER IS THE LIBRARY (K, 2026-10-20). One page, two states told apart by
# Tinkerex::LibraryRoot.pending?: the first-run confirmation, and once chosen, the change form. On s3
# and chunk_remote it renders the "where files come from" partial with nothing to choose, so the
# Settings link never leads to a dead end. Session-authed like every Settings page.
#
# ONLY AN ADMIN CHOOSES THE FOLDER (2026-10-21, the owner's call once Settings → Users gave the server
# an admin). On share every account indexes the one library, so a change rescans every account's
# catalog and Start over forgets every account's files: the change is to the SERVER, not to the
# account making it. Every other account sees the folder and its state, read-only. The gate asks
# User#can_manage_accounts?, the Users page's own answer, so the shared demo never passes it whatever
# its row says -- and is still refused first, by name. First run is no exception: every door that
# makes the first account makes it the admin (sign-up, tinkerex:owner), and a plain account that
# meets a pending library waits on the read-only page until an admin confirms it. `children` is gated
# with `update`: it lists the MOUNT, folders outside the library, and only the change form calls it.
module Settings
  class LibraryController < ApplicationController
    # The page the redirect points at must not redirect to itself.
    skip_before_action :require_library_folder!
    before_action :require_share!, only: %i[update children]
    before_action :refuse_demo_account!, only: :update
    before_action :require_admin!, only: %i[update children]

    def show
      load_page
    end

    # GET /settings/library/children?parent=<relative> -> the chooser's JSON, in the shape
    # lib/file_chooser.js already consumes ({parent, crumbs, entries: [{node_id, name, kind}]}), with
    # the path relative to the mount standing in for node_id. Directory NAMES under the mount, never
    # files and never contents; on share every account sees the one library already.
    def children
      listing = Tinkerex::LibraryRoot.children(params[:parent])
      render json: {
        parent: listing.parent,
        crumbs: crumbs(listing.parent),
        entries: listing.entries.map { |rel| { node_id: rel, name: File.basename(rel), kind: "dir" } },
        truncated: listing.truncated
      }
    rescue Tinkerex::LibraryRoot::Invalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # PATCH /settings/library {relative, start_over: "1"?}. Only the Start over button carries
    # `start_over`, so a plain submit -- Switch, Use this folder, or Enter in the form -- keeps the
    # catalog. The choice is validated, probed and written by Tinkerex::LibraryRoot.choose! before
    # anything is enqueued, so a refused folder changes nothing.
    def update
      first_run = Tinkerex::LibraryRoot.pending?
      # "Start over" only means something with a catalog to forget; on an empty one it is a switch.
      start_over = params[:start_over].present? && !Tinkerex::LibraryRoot.catalog_empty?
      rel = Tinkerex::LibraryRoot.choose!(params[:relative])

      if first_run
        # THE FIRST SCAN FOLLOWS THE CONFIRMATION, NOT THE SIGN-UP (K §3), through the sign-up
        # form's own door. Nothing can be scanning yet: pending paused every schedule.
        Library::ScanJob.enqueue_first_for(current_user)
        redirect_to root_path, notice: "Your library is #{display(rel)}. Indexing it now."
      else
        # ONE CHANGE PER USER, EACH BEHIND THAT USER'S RUNNING SCAN (Library::RootChangeJob): on share
        # every account indexes the one library, so every catalog follows the folder.
        User.find_each { |user| Library::RootChangeJob.perform_later(user_id: user.id, start_over:) }
        verb = start_over ? "Starting over with" : "Switching to"
        redirect_to settings_library_path(scanning: 1), notice: "#{verb} #{display(rel)}."
      end
    rescue Tinkerex::LibraryRoot::Invalid => e
      @error = e.message
      load_page
      render :show, status: :unprocessable_entity
    end

    private

    def load_page
      @share = Tinkerex::LibraryRoot.share?
      return unless @share

      @can_change = current_user.can_manage_accounts?

      @pending = Tinkerex::LibraryRoot.pending?
      @relative = Tinkerex::LibraryRoot.relative.to_s
      @catalog_empty = Tinkerex::LibraryRoot.catalog_empty?
      @file_count = current_user.nodes.present.where(kind: "file").count
      # The ADAPTER's root, the one actually in use, rather than a second join of the two halves.
      @root_missing = !@pending && !FileLayer.current.root.directory?
      @refusal = current_user.library_scan_refusal
    end

    def display(rel) = rel.empty? ? "the whole mounted folder" : rel

    def crumbs(rel)
      segments = rel.split("/")
      segments.each_index.map { |i| { node_id: segments[0..i].join("/"), name: segments[i] } }
    end

    def require_share!
      return if Tinkerex::LibraryRoot.share?

      message = "This library has no folder to choose."
      respond_to do |format|
        format.json { render json: { error: message }, status: :not_found }
        format.html { redirect_to settings_library_path, alert: message, status: :see_other }
      end
    end

    def refuse_demo_account!
      return unless Tinkerex::Demo.demo?(current_user)

      redirect_to settings_library_path, alert: "The shared demo account can't change the library folder.",
                                         status: :see_other
    end

    def require_admin!
      return if current_user.can_manage_accounts?

      message = "Only an admin can change the library folder."
      respond_to do |format|
        format.json { render json: { error: message }, status: :forbidden }
        format.html { redirect_to settings_library_path, alert: message, status: :see_other }
      end
    end
  end
end
