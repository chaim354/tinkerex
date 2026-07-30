# THE EAGER NUDGE (Task 11). A file uploaded into a project's folder attaches and files itself NOW
# rather than at the next sweep, which would read as broken — the same "the nudge is the fast path
# and the poll is the correctness fallback" shape the sync engine already uses (§12 step 1). The
# periodic Maker::ProjectIntake run is what makes it correct; this is what makes it feel instant.
#
# A CONCERN, NOT A THIRD COPY, and that is a decision worth recording rather than defaulting to —
# CLAUDE.md's own tally of the port_writable? branch is the precedent this follows: "a NEW [inline
# copy] needs an argument for being inline rather than a service, and a verb that more than one
# caller performs does not have one." Two upload doors already needed this exact rescue-and-call
# (FilesController#create/#finalize_upload); wiring in a THIRD (Projects::UploadsController#create,
# the project page's own inline share/s3 uploader) is the second caller crossing into "more than
# one" territory a second time, and copy-pasting the block below into a second controller — all of
# it, including the reasoning for why StandardError is right here and wrong in the service — is
# exactly the kind of drift this codebase keeps paying for and keeps writing down when it finds it
# again. (FilesController#enqueue_preview has a near-duplicate in Projects::UploadsController today
# — that pre-existing four-line, one-rescue duplication is a SMALLER trade this concern does not
# try to retroactively fix; it is not a precedent for adding a THIRD copy of this longer one.)
#
# BEST-EFFORT, AND RESCUED WIDELY — StandardError, not a named list — FOR THE SAME REASON in every
# controller that includes this: the write it follows has ALREADY SUCCEEDED (bytes in the store,
# node exists), so a failure here must never turn a successful upload into an error the user sees.
# StandardError IS RIGHT HERE, WHERE IT WOULD BE WRONG INSIDE THE SERVICE: this rescue exists to
# protect a response that has already succeeded, not to make a policy decision about what a failure
# means, and unlike Maker::ProjectIntake — which has already narrowed every condition it
# understands into named rescues (FileLayer::FetchError, FileLayer::NotFound,
# FileLayer::UnsupportedOperation, Maker::MoveNode::Collision/InvalidName) — a controller has no
# such catalog to narrow against. A bug here (a typo'd method, a nil that should not be nil) is
# exactly as unanticipated as a FileLayer outage, and both must fail the SAME way: log and let the
# upload the user actually asked for stand.
#
# CALL-SITE ORDERING, WHERE THIS CONCERN IS INCLUDED, IS NOT THIS FILE'S CALL — but it is worth a
# pointer here because it is easy to get backwards. Where a controller ALSO makes its own explicit
# `file_attachments.create!` for the same upload (Projects::UploadsController does; FilesController
# does not), that create! MUST run before this call, not after — see that controller for why.
module ProjectFolderIntake
  extend ActiveSupport::Concern

  private

  # `node&.file?` — NOT a bare truthiness check on `node` — because a node_id names a `file` for
  # every caller today, but Maker::ProjectIntake sweeps directories via #subtree_files and would
  # simply find nothing to do for one; the guard is here so a future caller of any upload door
  # cannot turn this into a wasted (or surprising) sweep by handing it a directory's node_id.
  # `current_user.nodes.present`, matching every other lookup in these controllers, so a node
  # tombstoned in the gap between the write and this call is treated as absent, not fed to the
  # service.
  #
  # `self.class.name` IN THE LOG LINE, NOT A HARD-CODED CONTROLLER NAME — this runs from more than
  # one controller now, and a literal name here would be quietly wrong in every caller but the one
  # it was written for, which is exactly the kind of small lie a shared concern must not tell.
  def intake_project_folder(node_id)
    node = current_user.nodes.present.find_by(node_id:)
    Maker::ProjectIntake.for_node(user: current_user, node:) if node&.file?
  rescue StandardError => e
    Rails.logger.warn("#{self.class.name}#intake_project_folder(#{node_id}): #{e.class}: #{e.message}")
  end
end
