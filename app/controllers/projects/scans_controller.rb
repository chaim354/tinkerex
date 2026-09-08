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
    #
    # THE NOTICE NO LONGER PROMISES A TIMED REFRESH (stage 4, S4-3). It used to say "in a moment —
    # reload again if nothing has appeared", which was the 6000 ms guess admitting to being one.
    # The element beside it now polls /files/scan_status until the scan actually stamps
    # users.library_scanned_at, so "when the scan finishes" is a claim the page can keep.
    def enqueue_scan
      Library::ScanJob.enqueue_for(current_user)
      redirect_to project_path(@project, scanning: 1),
                  notice: "Scanning your library for new files. This page refreshes when the " \
                          "scan finishes."
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
      # DISCOVERY BETWEEN THE PULL AND THE FILE (stage 4, S4-6; story 1.1). The pull is what makes
      # a folder another device pushed visible at all; discovery must run BEFORE the intake for the
      # reason Library::ScanJob#discover_projects gives at length — a newly adopted project's loose
      # files have no shelf nearer than `Projects` itself, so the wrong order hands the whole folder
      # to the model catalog, permanently.
      #
      # THE JOB, NOT Maker::ProjectDiscovery — the idiom Library::ScanJob already uses, and for the
      # same two reasons: the job is the only place a run is LOGGED, and #chain_intake is what
      # sweeps a project this call has just created (`.for_project` below sweeps THIS project only).
      # `perform_now` creates no job row, so ProjectDiscoveryJob's `limits_concurrency` does not
      # engage here — the same gap that job's own header records for Library::ScanJob's call. What
      # bounds it here is this controller's `rate_limit to: 3, within: 1.minute, by: user`. A
      # partial unique index on (user_id, folder_node_id) is the durable fix and is open work.
      #
      # EAGER_MAX_PROJECTS, NOT THE SWEEP'S CAP: this is a sweep inside a request, the entry point
      # Maker::ProjectDiscovery's cap comment said would owe a second cap (found in review — it
      # shipped without one). A capped run tells the maker "N of M; the rest on the next scan".
      run = Maker::ProjectDiscoveryJob.perform_now(user_id: current_user.id,
                                                   cap: Maker::ProjectDiscovery::EAGER_MAX_PROJECTS)
      result = Maker::ProjectIntake.for_project(user: current_user, project: @project)
      redirect_to project_path(@project), notice: scan_notice(result, run)
    end

    # How many created folders the flash will NAME before it starts counting. MAX_PROJECTS is 50,
    # and a flash listing fifty folder names is not a sentence.
    SCAN_NAMES_SHOWN = 3

    # The lead-in is this door's own; everything after it belongs to ProjectFolderIntake, so the
    # four doors cannot drift about how they phrase one collision. NO TRAILING PUNCTUATION on the
    # lead — the conflict form turns the period into a comma.
    #
    # THE DISCOVERY SENTENCE IS APPENDED, NOT WOVEN IN (stage 4, S4-6): what the intake did to THIS
    # project and what discovery did to the LIBRARY are two facts, and joining them into one clause
    # would make either one unreadable when the other is absent.
    def scan_notice(result, run)
      # DISCOVERY IS REPORTED ON EVERY BRANCH, THE NO-FOLDER ONE INCLUDED (found in review): the
      # early return below is about THIS project's folder, and discovery ran over the whole library
      # regardless — with decision 2 making a trashed folder the mainline, a maker whose project had
      # no folder was the one most likely to have just had ten projects created and told nothing.
      discovery = discovery_sentence(run)
      if result.status == :no_folder
        return [ "Scanned your library. #{@project.name} has no folder yet, so nothing was filed.",
                 discovery ].compact.join(" ")
      end

      # THE LEAD NO LONGER COUNTS WHAT WAS FILED — ProjectFolderIntake#project_intake_sentence says
      # it now, with the FOLDERS, which is strictly more than a number. Two doors saying the same
      # fact in two shapes is the drift this method's own comment already refuses.
      lead = if result.attached.zero? && result.moved.zero?
        "Scanned your library — nothing new for #{@project.name}"
      else
        "Scanned your library — attached #{result.attached}"
      end
      [ project_intake_sentence(lead, result, unfiled_by_conflict(result, result.skips.map(&:first))),
        discovery_sentence(run) ].compact.join(" ")
    end

    # WHAT DISCOVERY CREATED, BY NAME (stage 4, S4-6; story 1.1). Discovery reported to the log and
    # nowhere else — a folder became a project and the only witness was a log line the maker never
    # reads. NIL WHEN IT CREATED NOTHING, because "already claimed" is the steady state and a
    # sentence on every click meaning nothing happened is noise, which is the argument
    # Maker::ProjectDiscovery::RunResult's own header makes for having no skips breakdown at all.
    #
    # `respond_to?` RATHER THAN A NIL CHECK: the value comes back from ActiveJob's `perform_now`,
    # which answers whatever #perform returned — nil if a callback ever halts the job — so this
    # asks what it can do rather than assuming what it is.
    #
    # A CAPPED RUN SAYS SO IN THE SAME SENTENCE (orchestrator decision 4). `created` alone reads as
    # "that was all of them", and a maker would go looking for the folders the cap deferred
    # believing the app had refused them. `candidates` and `cap` were already on the RunResult for
    # exactly this.
    def discovery_sentence(run)
      return nil unless run.respond_to?(:created) && run.created.positive?

      shown = run.names.first(SCAN_NAMES_SHOWN)
      rest  = run.names.size - shown.size
      tail  = rest.positive? ? "#{shown.join(", ")} and #{rest} more" : shown.to_sentence
      found = "Found #{run.created} new #{"project".pluralize(run.created)}: #{tail}."
      return found unless run.status == :capped

      "#{found} That is #{run.created} of #{run.candidates} folders under " \
      "#{Maker::ProjectFolders::ROOT}/; the rest on the next scan."
    end
  end
end
