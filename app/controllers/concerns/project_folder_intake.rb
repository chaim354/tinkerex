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
#
# THE RETURN VALUE USED TO BE THROWN AWAY BY EVERY CALLER, AND THAT WAS A REAL REGRESSION, NOT A
# HARMLESS ONE. #intake_project_folder answers exactly what Maker::ProjectIntake.for_node answers —
# nil (the node is not under any project folder this user owns) or a Result (see
# Maker::ProjectIntake::Result) — with ONE addition: a rescued failure ALSO answers nil, explicitly,
# so "something went wrong in here" reads to a caller exactly like "there was nothing to report",
# never like a Result it could misread. That nil-or-Result contract is what makes
# #left_unfiled_by_conflict? below safe to call on whatever this method hands back, unconditionally.
# Before this fix, every caller called this only for its side effect (the actual filing) and
# discarded what it returned — which is how a same-named upload's eager nudge losing a collision at
# its destination folder went from "the write itself was refused, with a flash" (before the eager
# nudge existed) to "the write quietly succeeds, the file quietly stays at the project root, and the
# user sees a plain 'Uploaded x.' with no sign anything unusual happened" (after the eager nudge,
# before this fix) — the SAME outcome (two distinct files, nothing lost), MISSING feedback. See
# #left_unfiled_by_conflict? and #project_intake_notice below, and
# project_upload_attach_test.rb's long-standing "duplicate filename" test for the full accounting of
# the mechanism this restores feedback for, without changing it.
#
# THE RETURN VALUE IS NOW READ FOR WHAT THE SWEEP FILED AS WELL AS FOR WHAT IT COULD NOT (stage 4,
# S4-2; stories 1.5, 4.1): #filed_sentence names the file and the folder off Result#plan, so an
# upload no longer lands on a page that visibly sorted itself while the flash said nothing.
# AND THE CONFLICT'S FOLDER COMES OFF THE Result (#conflict_folders) rather than being re-derived
# here — see
# #conflict_folder for the one file whose destination the name alone cannot answer.
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
  #
  # RETURNS nil OR A Maker::ProjectIntake::Result — NEVER ANYTHING ELSE. The `if node&.file?` guard
  # already answers nil when there is no node to sweep; the explicit `nil` in the rescue clause is
  # what keeps a rescued failure in that same, safe shape. Without it this method would return
  # whatever Rails.logger.warn happens to return (Ruby's Logger#add always answers `true`, so
  # #left_unfiled_by_conflict? below would still read it as "nothing to report" today) — but
  # spelling it out means that safety does not quietly depend on Logger's own return value forever.
  def intake_project_folder(node_id)
    node = current_user.nodes.present.find_by(node_id:)
    Maker::ProjectIntake.for_node(user: current_user, node:) if node&.file?
  rescue StandardError => e
    Rails.logger.warn("#{self.class.name}#intake_project_folder(#{node_id}): #{e.class}: #{e.message}")
    nil
  end

  # Did THIS upload's own file get left at the project root because a file already occupied its
  # destination category folder — #intake_project_folder's Result carrying a `[name, :conflict]`
  # entry in `skips` for exactly this file? The one question a caller has once the nudge has run
  # (see the header above for why that question used to go unanswered).
  #
  # MATCHES ON NAME, BECAUSE NAME IS ALL Result#skips HAS. Maker::ProjectIntake#file_all records
  # `[node.name, reason]` (see #skip in app/services/maker/project_intake.rb) — never a node_id —
  # so a caller here is asking the most precise question this data can honestly answer, not an
  # approximation of a more precise one that exists somewhere and was left out.
  #
  # THE HONEST LIMIT, NAMED RATHER THAN GUESSED PAST: two DIFFERENT loose files that happen to
  # share this node's exact name, both skipped with :conflict in the SAME sweep, cannot be told
  # apart by name alone — "was MY upload the one that collided" cannot always be answered with
  # certainty from outside #file_all's own loop. This is not a gap introduced here: it is the same
  # ambiguity #file_all's own skip-logging already lives with (its log line names the file by
  # `node.name`, not by which upload triggered the sweep). In practice #for_node sweeps ONE
  # project's OWN root, triggered by ONE fresh upload, so the ordinary case has at most one
  # same-named collision to report and the answer is exactly right; the rare case where it is not (a
  # second, unrelated same-named file already sitting loose in that same project) still reports
  # something TRUE about the project — a file by this name did fail to file — not something false.
  def left_unfiled_by_conflict?(intake_result, name)
    return false unless intake_result.is_a?(Maker::ProjectIntake::Result)

    intake_result.skips.any? { |skipped_name, reason| reason == :conflict && skipped_name == name }
  end

  # The "Uploaded <name>." notice every flash-producing door here already wanted, with the missing
  # half restored: when #left_unfiled_by_conflict? is true, it says WHERE the collision left the
  # file instead of staying silent about it. ONE wording, shared, so a caller in FilesController and
  # a caller in Projects::UploadsController cannot drift apart on how they phrase the identical fact
  # (CLAUDE.md's rule for a verb more than one caller performs, applied to a sentence here rather
  # than to a branch).
  #
  # WORDED AS SUCCESS, NOT AS A FAILURE — because it is one: the file WAS uploaded and IS attached
  # to the project, exactly as durable as the file that DID get filed (Maker::AttachToProject's
  # rule: attach is durable, filing is best-effort). "but" introduces where it landed, not an
  # apology for what went wrong.
  def project_intake_notice(intake_result, filename)
    project_intake_sentence("Uploaded #{filename}", intake_result, filename)
  end

  # THE SAME SENTENCE WITH THE LEAD-IN LEFT TO THE CALLER, because the doors genuinely differ on
  # that half and must not differ on this one. An upload door says "Uploaded grid.svg"; the addon
  # save doors say "Saved “3mm birch test”" — the state's name, not a filename, since one save can
  # write several files. What follows the lead-in is the identical fact about the identical
  # mechanism, so it has one home here rather than a paraphrase per controller (CLAUDE.md's rule for
  # a verb more than one caller performs, applied to a sentence).
  #
  # THE LEAD-IN CARRIES NO TRAILING PUNCTUATION, deliberately: the conflict form turns the period
  # into a comma ("Uploaded x, but …"), so a caller that supplied its own "." would produce
  # "Uploaded x., but …". #project_intake_notice above is now this method's first caller rather than
  # its owner, and its output is byte-identical to what it produced before this extraction — pinned
  # by project_upload_attach_test.rb and project_folder_intake_test.rb, which assert the full string.
  #
  # A nil `filename` IS A LEGAL INPUT and answers the plain lead-in: #unfiled_by_conflict below
  # answers nil when a save had no collision, and threading that straight through is what keeps the
  # addon door free of its own `if`.
  def project_intake_sentence(lead, intake_result, filename)
    if left_unfiled_by_conflict?(intake_result, filename)
      return "#{lead}, but a file of that name is already in " \
             "#{conflict_folder(intake_result, filename)}/, so this one stayed at the project root."
    end

    filed = filed_sentence(intake_result, filename)
    filed ? "#{lead}. #{filed}" : "#{lead}."
  end

  # THE FOLDER THE SWEEP ACTUALLY TRIED. Read off Result#conflict_folders, which
  # Maker::ProjectIntake#place records as it collides — never re-derived here. The fallback keeps a
  # Result built without the map (a test double, an older caller) reading exactly as it did before.
  #
  # THE RE-DERIVATION WAS RIGHT FOR EVERY FILE WHOSE DESTINATION COMES FROM ITS NAME AND WRONG FOR
  # THE ONE WHOSE DESTINATION COMES FROM ITS CONTENT: a board zip collides in `pcb/` while
  # `folder_for` answers `archives/` (stage 4, S4-2).
  def conflict_folder(intake_result, filename)
    intake_result.conflict_folders[filename].presence ||
      Maker::ProjectFolders.folder_for(current_user, filename)
  end

  # WHAT THE SWEEP JUST DID, IN THE FLASH (stage 4, S4-2; stories 1.5, 4.1). The sweep moved the
  # maker's file and said nothing, so an upload landed on a page that visibly did not sort and the
  # only record was a log line. READ OFF Result#plan — the [name, folder] pairs #place BUILT AS IT
  # MOVED — so what this names and what the sweep did cannot disagree.
  #
  # THE UPLOADED FILE BY NAME WHEN IT IS THE ONLY ONE, a count otherwise: a save writes a SET, and
  # "Filed 3 files into design/, docs/." is what the maker needs to know to go look. `to_sentence`
  # is ActiveSupport's; the pluralisation is spelled out because `pluralize` is a VIEW helper and
  # this is a controller concern.
  def filed_sentence(intake_result, filename)
    return nil unless intake_result.is_a?(Maker::ProjectIntake::Result)

    plan = intake_result.plan
    return nil if plan.empty?

    mine = plan.find { |name, _folder| name == filename }
    return "Filed #{mine.first} into #{mine.last}/." if mine && plan.size == 1

    folders = plan.map(&:last).uniq.sort.map { |f| "#{f}/" }
    "Filed #{plan.size} file#{"s" unless plan.size == 1} into #{folders.to_sentence}."
  end

  # The first of `names` this sweep left at the project root because its destination category folder
  # was taken, or nil. THE PLURAL FORM of #left_unfiled_by_conflict?, and it exists because an addon
  # save writes a SET of files in one request while every upload door writes one — asking only about
  # the first file would report "Saved" with no qualification for a save whose SECOND output
  # collided, which is the same missing-feedback regression #left_unfiled_by_conflict? was added to
  # end. Reports the first, not all of them: the flash is one sentence, and one named collision is
  # what makes the user go look.
  def unfiled_by_conflict(intake_result, names)
    Array(names).find { |name| left_unfiled_by_conflict?(intake_result, name) }
  end
end
