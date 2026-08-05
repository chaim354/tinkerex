module Maker
  # Attach a library file to a project, and decide what that means for where the bytes live.
  #
  # THE POLICY LIVES HERE BECAUSE IT HAS MORE THAN ONE DOOR, and the extraction is not tidiness —
  # it is the fix for a real bug. The rules used to sit inline in
  # Projects::AttachmentsController#create, and when #relocate was added it called the MOVE
  # directly, below every one of them. Three rules did not come along, and the worst of them was
  # the bundle guard: #relocate pulled `widget.stl` out of `Models/widget/` and reported
  # "Moved widget.stl into Desk Lamp", leaving the model's folder holding two of its three files.
  # Copy-pasting the guards into the second door would have left the trap set for the third, so
  # every rule is now a decision a door must pass or explicitly opt out of IN WRITING.
  #
  # THE RULES, all of them, in #refusal_for:
  #   :not_a_file         — a directory has no place in a project folder, and FileLayer::S3#move
  #                         refuses one outright (movable_file!), so relocating one would be a
  #                         policy that silently works on share/chunk and 422s on s3.
  #   :model_bundle       — the file belongs to a Maker::Model. An imported model is its STL plus
  #                         instructions plus cover plus source archive, curated into
  #                         Models/<slug>/ by the importer; moving ONE of them out guts the folder.
  #                         MEMBERSHIP IS THE ATTACHMENT, NOT THE FOLDER — a file can be moved out
  #                         of Models/<slug>/ and still belong to the model, and a stray file can
  #                         be dropped in and not belong, so the maker_file_attachments row is what
  #                         this asks. (The alternative reached for first — move the model's whole
  #                         FOLDER into the project — is refused by FileLayer::S3#move for the same
  #                         reason as above: S3 has no directory and no rename.)
  #   :attached_elsewhere — another project already claims it, and a file should not be yanked out
  #                         of the folder that project put it in. THE ONLY ONE OF THE THREE THAT IS
  #                         POSITIONAL — its reason is about the move's SOURCE — so it is the only
  #                         one a caller can opt out of, via `within_own_folder:` (see #refusal_for).
  #                         Maker::ProjectIntake#place does, because its move never leaves the folder
  #                         this project already owns. The other two are unconditional.
  #
  # THE ATTACH IS THE DURABLE HALF AND THE MOVE IS BEST-EFFORT. A collision or an unmounted NAS
  # must never lose the attachment: it is a reference the user asked for, and it is exactly as true
  # with the bytes in the old folder. Every move outcome is a SYMBOL rather than a raise, because
  # each one is a normal thing that happens to a user's library and the caller words a different
  # sentence for each — an exception would make the happy path the only one written down.
  #
  # §10 BOUNDARY: this is maker-layer policy. It reaches the bytes only through Maker::MoveNode,
  # which owns the port-vs-sync branch; nothing here touches Sync::*, the changelog or the port.
  class AttachToProject
    # What an attach did, in the terms BOTH doors report — the HTML flash and the JSON body have to
    # tell the same story, and the status code cannot carry the relocation because the attach
    # really did succeed.
    #
    # `attachments` is a list because a bundle attach is N rows; `created` is a flag rather than
    # the new rows because the bundle write is a bulk insert_all and there are no instantiated
    # records to ask. `model` is non-nil only on the bundle path, and is what the caller needs to
    # say "Attached 3 files from Widget."
    Result = Data.define(:attachments, :relocation, :created, :model)

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    # Attach `node` and relocate it if the policy allows. The door Projects::AttachmentsController
    # #create drives, from all three of its own paths (the file page's dropdown, the project page's
    # picker, and the project page's inline upload).
    def call(node)
      # A DIRECTORY NEVER TAKES THE BUNDLE PATH, and `node.file?` here is a bug fix, not symmetry.
      # Models::AttachmentsController does not filter by kind, so a dir CAN be attached to a model
      # — and #attach_bundle keeps live FILES only, so the triggering node was then absent from its
      # own result. The HTML door said "Attached 0 files from Widget." and the JSON door raised
      # `undefined method 'node_id' for nil`; both reproduced. A dir has nothing to relocate under
      # any rule, so the ordinary path (attach the row, move nothing) is the coherent answer, and
      # this is what makes #attach_bundle's "the triggering node is always in there" true.
      model = model_owning(node) if node.file?
      return attach_bundle(model) if model

      # READ BEFORE THE CREATE. `attached_elsewhere?` excludes this project by id, so today the
      # order changes nothing — but the rule is "was it claimed by another project when we
      # arrived", and asking first is what keeps that true however the query is later written.
      refusal = refusal_for(node)

      # create_or_find_by!, not find_or_create_by! or create! (Task 9a's follow-up) — and NOT
      # because find_or_create_by! was broken here. Correcting a real mistake in this task's first
      # pass: find_or_create_by! LOOKS like find_by(attrs) || create!(attrs) — the naive shape,
      # with no protection for a writer landing the identical
      # (user, attachable_type, attachable_id, node_id) tuple in the gap between the two — and a
      # first draft of this comment said exactly that, reporting #call as newly exposed to an
      # uncaught ActiveRecord::RecordNotUnique the moment the table gained a unique index. THAT WAS
      # WRONG: in this Rails version, find_or_create_by!(attrs, &block) is actually
      # find_by(attrs) || create_or_find_by!(attrs, &block) (source-checked, and pinned by this
      # method's own race test) — so the fallback ALREADY went through create_or_find_by!'s
      # savepoint-and-rescue, and a race here was already survived before this line ever changed.
      # find_or_create_by! did the wrong thing for the WRONG diagnosis to look right — bare
      # create!/save! really do raise uncaught under this exact race, which is genuinely why
      # Models::AttachmentsController#create and Projects::EntryPhotosController#create needed
      # fixing, and it is tempting to assume every writer of this table shared that exposure.
      #
      # SPELLED OUT EXPLICITLY ANYWAY, for two reasons that hold regardless of the correction
      # above: it costs one fewer query in the ordinary (non-racing, genuinely new attachment)
      # case — create_or_find_by! attempts the INSERT first and only falls back to a SELECT on
      # conflict, where find_or_create_by! always pays for the SELECT up front — and it makes the
      # race-safety a fact ABOUT THIS LINE rather than an inherited property of Rails' internals
      # that a future reader has no reason to go and check (as this task's first pass did not).
      # `previously_new_record?`, read a few lines down for `Result#created`, needed no change for
      # this: it is false for a record loaded by create_or_find_by!'s own rescue find, exactly as
      # it already was for the ordinary already-attached case. THE ATTRIBUTES ON THE RETURNED ROW
      # ARE THE WINNER'S, NOT OURS, on that path — `att.role` can be whatever the other request
      # set, not role_for(node.name) as computed below — correct, since "already attached" means
      # deferring to the row that is actually there.
      #
      # THE RESIDUAL RACE, NAMED RATHER THAN LEFT FOR SOMEONE TO REDISCOVER: create_or_find_by!'s
      # own rescue does find_by!(attrs), which raises ActiveRecord::RecordNotFound if the row that
      # won the race is gone again by the time this reads it (detached microseconds after being
      # attached). That window is narrower than the one this closes — a row has to be created AND
      # deleted inside this one request's create-then-find gap — and it is NOT special-cased: it
      # propagates uncaught, the same as any other "the thing I was just told exists no longer
      # does" failure this codebase leaves loud (LibraryCapabilities' argument for un-rescued
      # NotImplementedError makes the same call). Deliberately not silently swallowed.
      #
      # THIS SERVICE IS NOT THE ONLY WRITER, EITHER — CLAUDE.md counts six others
      # (Projects::UploadsController, Models::AttachmentsController,
      # CurrentProject#attach_addon_files_to_current_project, Projects::EntryPhotosController,
      # V1::Maker::FileAttachmentsController, and #attach_bundle below), which is why a
      # database-level constraint, not merely this method's own care, is what makes "no duplicate
      # row" actually true.
      att = @project.file_attachments.create_or_find_by!(user: @user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end

      # nil, NOT a refusal symbol, when the policy said no: "not moved" and "never tried" are
      # different facts, and #create's JSON door reports the second as a present-and-null key.
      # (#relocate wants the reason, which is why #refusal_for is public and separate.)
      Result.new(attachments: [ att ], relocation: (move(node) if refusal.nil?),
                 created: att.previously_new_record?, model: nil)
    end

    # Finish a move the attach could not do — the collision prompt's "Move it in as …" button.
    # Answers a refusal symbol or a move outcome; never raises for anything a user can cause.
    #
    # THE ATTACHMENT MUST ALREADY EXIST. Without this, POSTing a node_id to a project the user
    # never attached anything to moved the file in AND created Projects/<slug> as a side effect —
    # an action on the attachments controller that touched no attachment. "Attached ⇒ in the
    # folder" is the rule; a file that has not joined the project has nothing to finish.
    def relocate(node, new_name: nil)
      return :not_attached unless attached_here?(node)

      refusal_for(node) || move(node, new_name:)
    end

    # Why a relocate would be refused, or nil if the policy allows it. PUBLIC because the conflict
    # prompt has to ask the same question before OFFERING the button: rendering a dialog wired to a
    # move that will be refused is how the bundle case became reachable from the UI at all.
    #
    # `within_own_folder:` — THE CALLER'S MOVE KEEPS THE FILE INSIDE THE FOLDER THIS PROJECT ALREADY
    # OWNS, so the :attached_elsewhere arm does not apply to it. Maker::ProjectIntake#place is that
    # caller and today the only one: it moves `Projects/<slug>/x.svg` to
    # `Projects/<slug>/design/x.svg`.
    #
    # THE RULE IS POSITIONAL, WHICH IS WHY IT CAN BE SCOPED AT ALL. Its stated reason (see the header
    # above) is that "a file should not be yanked out of the folder that project put it in" — a fact
    # about the move's SOURCE. #call and #relocate move a file INTO this project's folder from
    # wherever it is, which may well be another project's folder, so there the rule bites. A move
    # that starts inside this project's own folder cannot be taking the file out of another
    # project's, so the precondition cannot hold and refusing is refusing for a reason that is not
    # there. Nothing about the other project's view changes either: node_id never changes across a
    # move (Maker::MoveNode's stated promise), so its attachment keeps pointing at the same file.
    #
    # IT WAS A REAL, SILENT, PERMANENT BUG, not a theoretical asymmetry. A file at a project root
    # that any OTHER project also claimed was skipped by every 15-minute sweep forever, recorded only
    # as a `skips` entry that nothing but `rake projects:organize` prints — and it is reachable
    # without doing anything unusual, because CurrentProject#attach_addon_files_to_current_project
    # attaches an addon's output to whatever project is CURRENT regardless of which folder the save
    # dialog wrote it into. One addon save into a second project's folder made that file
    # permanently unsortable.
    #
    # A KWARG HERE RATHER THAN #place IGNORING THE SYMBOL IT WAS HANDED. The three rules have one
    # home on purpose (this class's header records #relocate being written below all of them), and a
    # caller that filters the ANSWER is a second place that has to know what each symbol means — the
    # drift this class exists to end. The caller states its SITUATION; the policy decides.
    #
    # SCOPED TO THIS ARM ONLY. :not_a_file and :model_bundle still refuse — the bundle rule is
    # deliberately about the ATTACHMENT rather than the folder ("MEMBERSHIP IS THE ATTACHMENT, NOT
    # THE FOLDER", above), so unlike this one it is not a claim about where the file currently sits
    # and there is no equivalent argument for relaxing it.
    def refusal_for(node, within_own_folder: false)
      return :not_a_file unless node.file?
      return :model_bundle if model_owning(node)
      return :attached_elsewhere if !within_own_folder && attached_elsewhere?(node)

      nil
    end

    # The Maker::Model this node belongs to, or nil. PUBLIC for the same reason #refusal_for is:
    # the caller that has to word ":model_bundle" needs the model's title, and a second copy of
    # this query in a controller is the duplication this class exists to end.
    #
    # SCOPED TO THE USER through the attachments
    # table: maker_file_attachments keys files by a bare node_id string with no FK, so an unscoped
    # lookup would happily find another user's row pointing at the same id and attach that
    # stranger's whole bundle into this project.
    #
    # One row, not a set: a file attached to two models is storable (Models::AttachmentsController
    # can do it) and there is no sensible way to attach "both bundles" to one project without
    # surprising the user, so the oldest row wins. The single-file rule is what the second model
    # loses, not its files.
    #
    # `order(:id)` IS THE RULE, NOT DECORATION. A bare find_by is LIMIT 1 over an UNORDERED set: on
    # SQLite it happens to come back lowest-id-first, but on the managed Postgres deployment the
    # row depends on the plan, so an unrelated UPDATE to either row could silently switch which
    # model a file belongs to between two requests. A sentence saying "the first row wins" has to
    # be enforced by the query, or it is a guess about a query plan.
    def model_owning(node)
      @user.maker_file_attachments
           .where(node_id: node.node_id, attachable_type: "Maker::Model")
           .order(:id).first&.attachable
    end

    private

    def attached_elsewhere?(node)
      @user.maker_file_attachments
           .where(node_id: node.node_id, attachable_type: "Maker::Project")
           .where.not(attachable_id: @project.id).exists?
    end

    def attached_here?(node)
      @project.file_attachments.exists?(node_id: node.node_id)
    end

    # Attach every one of the model's LIVE FILES to this project. Idempotent per file, so
    # re-attaching a bundle — or attaching one whose cover the user already attached by hand —
    # adds no duplicate row. Moves NOTHING, which is why it is identical on all three backends.
    #
    # The role is derived PER FILE from its own name: a bundle is a PDF and a PNG and an STL, so
    # copying the triggering file's role would label the instructions "model".
    def attach_bundle(model)
      node_ids = model.file_attachments.pluck(:node_id)

      # LIVE FILES ONLY, and `kind` is as load-bearing as `deleted`. A member the user deleted is a
      # tombstone; a member that is a directory is not a file — and projects/_attachments.html.erb
      # renders EVERY row as a file tile linking to file_path(node_id), so either one is a broken
      # row on the project page. #refusal_for rejects directories for a different reason (S3 cannot
      # move them); this one rejects them because the project page cannot show them. Two reasons,
      # one answer — the file must not give the directory question two.
      names = @user.nodes.present.where(node_id: node_ids, kind: "file")
                   .pluck(:node_id, :name).to_h
      # `&` DEDUPES. It also keeps the receiver's order, and this line used to CLAIM that "the
      # project lists the bundle the way the model does" — which is not something either end can
      # currently promise, so the claim is gone rather than enforced:
      #
      #   - THE DESTINATION cannot promise it. `insert_all` below omits `position`, so every row it
      #     writes takes the column default 0 — as does every other row this table has ever held
      #     (no writer anywhere in the app sets it; only the v1 API even permits it). So
      #     `has_many -> { order(:position) }`, which is how ProjectsController#show reads them,
      #     degenerates to ORDER BY over a total tie. The order survives on SQLite because a tie
      #     comes back in rowid order; on the managed Postgres deployment it is the plan's to
      #     choose — the exact reliance #model_owning three methods above says must not be trusted.
      #   - THE SOURCE cannot promise it either, and that is why setting `position` here was
      #     REJECTED rather than merely skipped. `node_ids` is read from
      #     `model.file_attachments.pluck(:node_id)`, which is the SAME all-zero
      #     `ORDER BY position ASC` (verified). Stamping positions on the project's rows would
      #     faithfully preserve an order that was already a guess, while making this the one writer
      #     in the app with a position convention — a later ordinary attach lands at 0 and
      #     leapfrogs the bundle. Enforcing bundle order is a change to the COLUMN's meaning across
      #     all six writers of this table, not a change to this line.
      #
      # THE DEDUPE WAS THE LOAD-BEARING HALF UNTIL TASK 9a, AND WHAT REMAINS IS NARROWER, NOT
      # GONE. Before that migration's unique index, two attachment rows for the SAME user on one
      # node were storable on the model side too, so a duplicate member would make the notice say
      # "4 files" for a three-file model AND insert that row twice — exactly what
      # test/integration/web/attach_model_bundle_test.rb used to construct on purpose, until the
      # index made the setup itself raise (see that test's own comment for the full story). `&`'s
      # FILTER half — keeping only ids that are ALSO live files in `names` — is unaffected and
      # still does real work regardless: node_ids and names come from two SEPARATE queries, not
      # one join, so a member whose node was deleted or is a directory still has to be dropped
      # here. `&`'s DEDUPE half is not entirely vestigial either, even for same-VALUE duplicates:
      # the unique index is scoped by the ATTACHING user, not by the model's owner, and
      # `model.file_attachments` carries no user_id scope of its own — so node_ids could still
      # repeat a value if two DIFFERENT users each hold a row naming this model and the same
      # node_id (not proven reachable through any controller today; not foreclosed by the schema
      # either). Nothing downstream saves it in that case: Array#- (below) removes matching
      # elements but does NOT dedupe its receiver — measured, after a comment here once claimed it
      # did. So `#select` still is not a safe refactor of this line, even though the scenario it
      # was ORIGINALLY written for is gone.
      members = node_ids & names.keys

      # FIVE QUERIES, CONSTANT IN N — deliberately not one SELECT + one INSERT per member. That
      # loop cost 2 queries per file (a 200-file model measured 407 queries / 113 ms) and it ran
      # inside a write transaction, so on the SQLite self-host deployment the write lock was taken
      # at the first INSERT and held to COMMIT: one bundle attach stalled every other writer in the
      # app. This is the shape stat_all and the Reconciler already had to fix, for the same reason.
      existing = @project.file_attachments.where(node_id: members).pluck(:node_id)
      rows = (members - existing).map do |node_id|
        { user_id: @user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id:, role: Maker::FileAttachment.role_for(names[node_id]) }
      end

      # insert_all SKIPS VALIDATIONS, so what they were protecting has to hold by construction, and
      # it does: role_for answers a member of ROLES for ANY input (it fetches with an "other"
      # default), node_id comes from a nodes row so it is present, and user/attachable are set
      # right here. There are no callbacks on Maker::FileAttachment to lose, `position` has a DB
      # default, and insert_all DOES stamp created_at/updated_at (record_timestamps) — both are
      # NOT NULL, so a Rails that stopped doing it would fail loudly rather than quietly.
      #
      # IT ALSO MAKES THE WRITE ONE STATEMENT, WHICH IS NOW THE WHOLE ATOMICITY STORY. A
      # half-attached bundle is worse than none — it is the gutted-folder failure again, wearing
      # the attachment table instead of the library — and a single INSERT cannot half-apply, so the
      # transaction that used to say this is gone rather than merely unnecessary. (A bundle is tens
      # of files; nothing here is sized for a bind-parameter limit.)
      #
      # unique_by:, MATCHING Maker::ProjectIntake#attach's insert_all (Task 9a) — see that method's
      # comment for the full argument; the short version is precision, not a fix. Bare insert_all
      # here was never at risk of RAISING or DUPLICATING under a race: it defaults to
      # on_duplicate: :skip, and an absent unique_by: resolves to an untargeted ON CONFLICT DO
      # NOTHING that already tolerated a conflict on this table's one unique index (verified
      # against the emitted SQL, the same way ProjectIntake#attach's was). Naming the index is
      # still the right call for the identical reason it was there: an untargeted skip silently
      # absorbs a violation of ANY unique constraint this table ever gains, not only this one.
      # Sibling method, identical shape, one spelling — leaving the two written differently is
      # exactly the drift this codebase keeps paying to correct.
      Maker::FileAttachment.insert_all(rows, unique_by: :index_maker_file_attachments_uniqueness) if rows.any?

      Result.new(attachments: @project.file_attachments.where(node_id: members).to_a,
                 relocation: :model_bundle, created: rows.any?, model:)
    end

    # Move `node` into this project's library folder. The only thing here that touches bytes.
    #
    # THE NO-OP RULE IS "SAME FOLDER, SAME NAME", and both spellings of "same name" have to be in
    # it. `new_name.nil?` is #call's (move under the node's own name); `new_name == node.name` is
    # #relocate's, and it is not decoration — the prompt's button is a POST, so a resubmit sends
    # the name the FIRST one already applied. Without that half the second submit is a real move to
    # where the file already is, which on chunk appends a redundant changelog `move` and broadcasts
    # it to every device. Renaming in place, by contrast, IS a real move and must not be
    # short-circuited.
    def move(node, new_name: nil)
      folder = @project.ensure_library_folder!(@user)
      same_name = new_name.nil? || new_name == node.name
      return :already_there if same_name && node.parent_node_id == folder.node_id

      Maker::MoveNode.call(@user, node:, new_parent_node_id: folder.node_id, new_name:)
      :moved
    rescue Maker::MoveNode::Collision
      :conflict
    rescue Maker::MoveNode::InvalidName => e
      # ITS OWN ANSWER, not :unavailable, because the two need opposite sentences: :unavailable
      # means "try again later" and a bad name NEVER succeeds on retry. move_node.rb asked for this
      # split by name — "someone typing '../evil' must be told the name is bad, not that the NAS is
      # down" — and #relocate is the caller it was anticipating, the first one that routes a
      # user-supplied name through here.
      log_failure(node, e)
      :bad_name
    rescue FileLayer::FetchError, FileLayer::NotFound, FileLayer::UnsupportedOperation => e
      # EVERY CLASS HERE IS NAMED, AND THE LIST IS DELIBERATELY NARROW. This rescue wraps the whole
      # method body, so anything it catches is reported to the user as "the library is having a bad
      # day" — which makes a too-wide list a machine for turning bugs into outage messages that no
      # test can see. It caught bare ArgumentError until a review drove the consequence: arity
      # drift in a port adapter's #move, a kwarg rename in MoveNode, or a nil reaching File.extname
      # anywhere below all became a 302 and a warn line, with a green suite. So:
      #
      #   FetchError           — the share is unmounted or the bucket is unreachable. Retryable.
      #   UnsupportedOperation — this backend refuses this move (S3 and directories; a destination
      #                          name taken in the store that the catalog did not know about).
      #   NotFound             — see below.
      #
      # ActiveRecord::RecordInvalid was in this list and is GONE: no producer was found on this
      # path (the move assigns a parent_node_id already checked live and a name #leaf! has already
      # vetted, and Node validates only node_id/name presence and kind inclusion), so it was a
      # guess — and an unjustified class here is exactly the bug-hiding shape above. If a real
      # producer turns up, add it back WITH its name.
      #
      # NotFound IS IN THIS LIST DELIBERATELY, and for BOTH doors it is not a caller error: each
      # resolves the node from `user.nodes.present` before calling (and #relocate additionally
      # requires `kind: "file"` and an existing attachment), and ensure_library_folder! has just
      # proved the destination exists. What is left is a race (tombstoned between those two
      # statements) or an out-of-band change under a share/s3 store. On the attach path the
      # attachment row is ALREADY COMMITTED, so letting it escape would 500 a request whose durable
      # half succeeded.
      log_failure(node, e)
      :unavailable
    end

    # :unavailable and :bad_name persist no marker anywhere, so after a NAS outage this line is the
    # entire audit trail for "which files failed to move". The node_id and slug are behavior, not
    # phrasing.
    def log_failure(node, error)
      Rails.logger.warn("attach relocate failed for node=#{node.node_id} project=#{@project.slug}: " \
                        "#{error.class}: #{error.message}")
    end
  end
end
