# HOST-SIDE SUBSCRIPTION to the sync engine's one extension point (Stage 3a Task 4; Sync::Hooks,
# boundary design §2). V1::CommitsController#finalize used to call ::Maker::Previews::Enqueue and
# ::Maker::ProjectIntakeJob.nudge directly; it now only fires Sync::Hooks.commit_finalized, and
# this file is where the host answers "and then what". A deployment that mounts the engine with no
# maker layer at all (goal 1 of the four-stage separation) simply never loads this initializer, and
# Sync::Hooks.commit_finalized is a plain no-op with nothing registered (see its own comment,
# property 3) — nothing about the engine's commit path requires this file to exist.
#
# THE SAME TWO CALLS, THE SAME ARGUMENTS, THE SAME ORDER AS BEFORE THE REFACTOR — this file's whole
# job is to be behaviourally invisible from outside the process. Do not "improve" the order, or add
# a third call here, without first re-reading both callees' own comments: ProjectIntakeJob.nudge's
# async+deduplicated shape is deliberate (it exists BECAUSE a synchronous sweep per commit was
# rejected — CLAUDE.md §12 item 10), and it firing after the preview enqueue rather than before was
# never load-bearing, but changing it without saying so here would make a future diff look like it
# might be.
#
# WRAPPED IN after_initialize, NOT REGISTERED AT THE INITIALIZER'S TOP LEVEL — same rule
# library_backend_check.rb states beside its own `after_initialize`: app/ constants (here,
# ::Maker::Previews::Enqueue, ::Maker::ProjectIntakeJob, and Sync::Hooks itself) are not
# autoloadable while config/initializers/*.rb are still loading, so a bare top-level call raises
# `uninitialized constant Sync` and takes the boot down before Puma binds a port — reproduced
# while writing this file (`bin/rails test` with no CI env var, so `config.eager_load` is off, per
# config/environments/test.rb). The BLOCK passed to on_commit_finalized still only runs later, per
# request, same as before; only the REGISTRATION call itself needed deferring.
Rails.application.config.after_initialize do
  Sync::Hooks.on_commit_finalized do |user:, node:, version:|
    # Eagerly render a thumbnail for a file synced from the desktop/API client, not just web
    # uploads. content_token == version_id in chunk mode. Best-effort BY CONSTRUCTION, not merely
    # by convention here: Sync::Hooks.commit_finalized itself rescues around every subscriber
    # call, so a raise from this line cannot fail the commit or change the response the client
    # already received — see Sync::Hooks' property 2, and the mutation check in
    # test/integration/v1/commit_finalize_hook_test.rb that proves it.
    ::Maker::Previews::Enqueue.call(user:, node_id: version.node_id, name: node.name,
                                    version_id: version.version_id)

    # And file it, if it landed at a project folder's root — closing CLAUDE.md §12 item 10's "a
    # device push through the mount gets no eager nudge for project-folder filing". This call used
    # to sit deliberately inline in V1::CommitsController rather than inside Sync::Commit#finalize,
    # on the argument that a controller (the top layer) reaching into Maker:: was less bad than the
    # engine's own service object doing so, which would invert the "maker is built ON sync"
    # layering. Sync::Hooks is what removes that dilemma entirely: the engine no longer reaches
    # into Maker:: from ANYWHERE, including the controller — this file is the HOST's own
    # initializer, and the host reaching into itself is not a layering violation, so there is no
    # longer a "least-bad layer" to argue about. See Maker::ProjectIntakeJob.nudge's own comment
    # for why this is an async, deduplicated enqueue rather than the synchronous sweep §12.10
    # rejected.
    ::Maker::ProjectIntakeJob.nudge(user:, node:)
  end
end
