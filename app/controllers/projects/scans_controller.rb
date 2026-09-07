module Projects
  # "Refresh my library from storage NOW", from a project page.
  #
  # WHAT IT DOES NOT DO: scan one folder. Library::Reconciler compares observations against the
  # WHOLE user catalog (#observable_live_paths -> #live_file_paths), so a Scanner rooted at a
  # project subfolder would list every file outside that subtree in #vanished_paths and trip the
  # mass-deletion guard. Library::ScanJob's own `root:` means A SHARE ROOT, not an arbitrary
  # folder. So this refreshes the LIBRARY and lets the existing chains do the per-project filing.
  #
  # IT ADDS NO FILING LOGIC. On share/s3 Library::ScanJob already runs
  # discover_projects -> intake_project_folders -> intake_models inline and strictly ordered; on
  # chunk_remote ChangelogSync nudges Maker::ProjectIntakeJob for live arrivals. This controller is
  # a new CALLER of unmodified machinery, which is why it can be this small.
  class ScansController < ApplicationController
    # For #project_intake_sentence / #unfiled_by_conflict on the chunk_remote branch. The conflict
    # clause has ONE home (docs/invariants/project-intake.md: the doors differ on the LEAD-IN and
    # must not differ on what follows), and a scan door is a fourth door onto that same sentence.
    include ProjectFolderIntake

    # DECLARED BEFORE the project lookup, deliberately: a throttle that does a database round-trip
    # before deciding to throttle is a weaker throttle, and `with:` therefore names the project by
    # its slug param rather than an ivar that does not exist yet.
    #
    # KEYED BY USER, not `by:`'s default request.remote_ip. This is a signed-in action, and the
    # thing being protected is one user's library walk, not an address.
    #
    # IT IS ALSO THE HONEST ANSWER TO A DOUBLE CLICK. Library::ScanJob carries
    # `limits_concurrency ... on_conflict: :discard`, so a second enqueue during a running scan is
    # SILENTLY DROPPED — without this the user would get "Scanning…" and nothing would happen.
    #
    # Counts in config.action_controller.cache_store. The test env sets :memory_store for exactly
    # this reason (§14e: NullStore#increment returns nil, so a throttle on the default test store
    # fires NEVER and its test passes for the wrong reason).
    rate_limit to: 3, within: 1.minute, by: -> { current_user.id },
               with: -> {
                 redirect_to project_path(params[:project_id]),
                             alert: "A scan just started for this library — give it a moment."
               }

    before_action :set_project

    def create
      if FileLayer.current.capabilities.scannable?
        enqueue_scan
      else
        pull_and_file
      end
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    # SHARE/S3 — ASYNC, AND IT MUST NOT FILE ANYTHING HERE. A NAS walk is why library_scan polls
    # every 15 minutes rather than every 15 seconds, so it cannot run in a request. And a move made
    # from here would race the Scanner's own observations: the Reconciler pairs the file back by
    # (content_hash, size) and repoints the node to its OLD path while the bytes sit at the new one,
    # a window in which a download gets a TERMINAL 404 for a file that is not gone. Running the
    # intake inline inside Library::ScanJob, after observer.call, is what makes that impossible.
    #
    # `scanning: 1` is what the page reads to schedule its one reload; scanreload_controller.js
    # navigates to the param-FREE url, which is what stops it looping.
    def enqueue_scan
      Library::ScanJob.enqueue_for(current_user)
      redirect_to project_path(@project, scanning: 1),
                  notice: "Scanning your library for new files. This page will refresh in a " \
                          "moment — a large library takes longer, so reload again if nothing " \
                          "has appeared yet."
    end

    # CHUNK_REMOTE — SYNCHRONOUS, AND THE ASYMMETRY IS THE POINT. There is no scan here, so there is
    # no race; a no-op pull is ONE GET (changelog_sync_test pins the count at exactly one) and the
    # intake is capped, so the work is bounded and belongs in the request, where it can report real
    # counts instead of a promise.
    #
    # THE INTAKE IS NOT REDUNDANT WITH THE PULL'S OWN NUDGE. ChangelogSync nudges
    # Maker::ProjectIntakeJob for LIVE FILE ARRIVALS ONLY, so files already in the mirror but
    # unfiled — a prior collision, a folder discovery has just adopted — get no nudge at all, and a
    # pull-only button would find nothing to do and read as broken. That case is the reason this
    # call is here.
    #
    # THIS IS NOT THE SYNCHRONOUS PULL §14a FORBIDS. That rule bars closing mirror staleness from
    # FilesController#index "or any other READ path". This is a POST — an explicit user command.
    # The journey test that pins a plain read as NOT seeing a server-side node is untouched.
    def pull_and_file
      FileLayer::RemoteChangelogPullJob.perform_now(user_id: current_user.id)
      result = Maker::ProjectIntake.for_project(user: current_user, project: @project)
      redirect_to project_path(@project), notice: scan_notice(result)
    end

    # The lead-in is this door's own; everything after it belongs to ProjectFolderIntake, so the
    # four doors cannot drift about how they phrase one collision. NO TRAILING PUNCTUATION on the
    # lead — the conflict form turns the period into a comma.
    def scan_notice(result)
      return "Scanned your library. #{@project.name} has no folder yet, so nothing was filed." if
        result.status == :no_folder

      # THE LEAD NO LONGER COUNTS WHAT WAS FILED — ProjectFolderIntake#project_intake_sentence says
      # it now, with the FOLDERS, which is strictly more than a number. Two doors saying the same
      # fact in two shapes is the drift this method's own comment already refuses.
      lead = if result.attached.zero? && result.moved.zero?
        "Scanned your library — nothing new for #{@project.name}"
      else
        "Scanned your library — attached #{result.attached}"
      end
      project_intake_sentence(lead, result, unfiled_by_conflict(result, result.skips.map(&:first)))
    end
  end
end
