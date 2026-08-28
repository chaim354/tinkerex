require "test_helper"
require "tmpdir"

module Maker
  # The intake policy, WITHOUT HTTP.
  #
  # PINNED TO CHUNK, like attach_to_project_test.rb, and for the same reason: the policy is
  # backend-neutral, but the move it drives is Maker::MoveNode's two-door branch and on share/s3
  # the port wants a real disk or bucket behind every fixture. The doors themselves are covered
  # per-backend in move_node_test.rb and library_folder_test.rb.
  class ProjectIntakeTest < ActiveSupport::TestCase
    setup do
      # A REAL SHARE LIBRARY, because these fixtures now have to exist on disk. Until Arc D Part 2
      # this suite ran against embedded chunk, where a node is just a row and a move is a changelog
      # entry -- so `nodes.create!` with no storage_path was a complete fixture. On share a move
      # resolves through storage_path and renames an actual file, which is CLAUDE.md §14a's
      # recorded trap in as many words: "a test fixture built with nodes.create! has a NULL
      # storage_path, which cannot exist on share/s3".
      @root = use_fresh_share_library!
      @user = User.create!(email: "pi-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # The path a node sits at, relative to the library root -- built from its parent chain so a
    # fixture's file lands where its node says it is. Without this the row and the disk disagree
    # and every move fails on a file that is not where the port looked for it.
    def rel_path_for(name, parent_node_id)
      parent = parent_node_id && @user.nodes.find_by(node_id: parent_node_id)
      parent&.storage_path.present? ? File.join(parent.storage_path, name) : name
    end

    # A live file node under `parent`, defaulting to the project folder's root (the inbox) --
    # WITH the bytes actually on disk, so the port can move it (see setup's note on §14a).
    def file(name, parent: @folder.node_id)
      rel = rel_path_for(name, parent)
      path = @root.join(rel)
      path.dirname.mkpath
      # ENAMETOOLONG IS TOLERATED, AND ONLY ENAMETOOLONG. One test here deliberately builds a name
      # the filesystem itself cannot hold ("a name too long to move is skipped, logged, and does
      # not abort the rest of the sweep") -- on embedded chunk that was just a long string in a
      # row, but on share the fixture cannot even be written. The ROW is what that test needs: the
      # sweep must find the node, fail to move it, log it, and carry on. Swallowing any wider class
      # of error here would let a genuinely broken fixture look like a passing test.
      begin
        path.binwrite("x")
      rescue Errno::ENAMETOOLONG
        nil
      end
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent, size: 1,
                          content_hash: SecureRandom.hex(8), storage_path: rel)
    end

    def dir(name, parent: @folder.node_id)
      rel = rel_path_for(name, parent)
      @root.join(rel).mkpath
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent,
                          storage_path: rel)
    end

    def intake = Maker::ProjectIntake.for_project(user: @user, project: @project)

    def roles = @project.file_attachments.pluck(:node_id, :role).to_h

    # Count real SQL round-trips inside the block, same shape as Sync::ScaleTest's helper of the
    # same name: `uncached` so the AR query cache can't make a repeat measurement read artificially
    # low, schema/transaction bookkeeping excluded so only real work counts.
    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        next if payload[:name] == "SCHEMA" || payload[:cached]
        next if payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|RELEASE|SAVEPOINT|PRAGMA)/i)
        count += 1
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      end
      count
    end

    # Every statement issued inside the block, as SQL strings. Same exclusions as count_queries.
    def capture_sql(&block)
      seen = []
      collector = ->(_name, _start, _finish, _id, payload) do
        next if payload[:name] == "SCHEMA" || payload[:cached]
        seen << payload[:sql]
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(collector, "sql.active_record", &block)
      end
      seen
    end

    # --- the shape of the walk ---------------------------------------------------
    #
    # THE ONE PART OF THE SWEEP THAT SCALES WITH THE LIBRARY, so its cost is a property worth
    # asserting rather than trusting. #subtree_files used to materialize a full Node for every file
    # under every project folder on every 15-minute sweep — ~10^5 AR instantiations per user at NAS
    # scale — to answer a question that reads four columns.
    #
    # IDENTIFYING THE WALK TOOK TWO TRIES, so the discriminator is spelled out. The sweep issues
    # several SELECTs mentioning parent_node_id, and most of them SHOULD select whole rows: the
    # folder lookups resolve `Projects`/`<slug>` by name, and #full_records deliberately re-loads
    # the inbox in full because Maker::MoveNode touches columns the walk omits. A blanket "nothing
    # selects nodes.*" would forbid those and fail for the wrong reason; matching on `IN (` fails
    # the other way, because a single-directory frontier renders as `= ?` and the walk goes unseen —
    # which is how the first version of this test passed vacuously (it asserted over an empty set).
    #
    # What is unique to the walk: it FILTERS ON parent_node_id and NOT on name. Every by-name
    # lookup carries a `"nodes"."name" = ` term; the walk never does.
    #
    # THREE TRIES NOW, and the third is worth recording because it is a different mistake from the
    # first two. `sql.include?("parent_node_id")` matched any query MENTIONING the column, including
    # one that merely SELECTS it — and Library::WorkingTree's ancestor walk (what the
    # :in_working_tree rule asks) hops up the tree with exactly that shape:
    # `SELECT parent_node_id WHERE node_id = ?`, no
    # name term. It was swept in as if it were the walk and failed the columns assertion, which read
    # as this guard catching a regression when nothing had regressed. Matching the WHERE clause is
    # what the prose above always claimed the filter did.
    test "the subtree walk selects only the columns it reads, never whole rows" do
      file("bracket.stl")
      dir("cad")

      walk = capture_sql { intake }.select do |sql|
        sql.match?(/\ASELECT/i) && sql.match?(/WHERE.*"nodes"\."parent_node_id"/m) &&
          !sql.match?(/"nodes"\."name" =/)
      end

      assert walk.any?, "expected to observe the breadth-first walk's own query"
      walk.each do |sql|
        assert_not sql.match?(/SELECT\s+"nodes"\.\*/i),
                   "the walk must not SELECT whole rows — it reads four columns: #{sql}"
        assert sql.include?(%("nodes"."kind")),
               "sanity: the walk names its columns explicitly: #{sql}"
      end
    end

    # --- the attach step ---------------------------------------------------------

    test "a file at the project folder root is attached" do
      node = file("bracket.stl")
      result = intake
      assert_equal 1, result.attached
      assert_equal "model", roles[node.node_id]
    end

    # THE HEADLINE CASE: dropped straight into a subfolder on the NAS, never at the root.
    test "a file nested in a subfolder is attached too" do
      sub = dir("design")
      node = file("panel.svg", parent: sub.node_id)
      assert_equal 1, intake.attached
      assert_equal "vector", roles[node.node_id]
    end

    test "a file two levels down is attached" do
      deep = dir("wip", parent: dir("design").node_id)
      node = file("draft.dxf", parent: deep.node_id)
      assert_equal 1, intake.attached
      assert_includes roles.keys, node.node_id
    end

    test "a file outside the project folder is not attached" do
      file("stray.stl", parent: nil)
      assert_equal 0, intake.attached
      assert_empty roles
    end

    test "a tombstoned file is not attached" do
      node = file("gone.stl")
      node.update!(deleted: true)
      assert_equal 0, intake.attached
    end

    test "directories are never attached" do
      dir("design")
      assert_equal 0, intake.attached
    end

    test "attaching is idempotent — a second run creates nothing" do
      file("bracket.stl")
      assert_equal 1, intake.attached
      assert_equal 0, intake.attached
      assert_equal 1, @project.file_attachments.count
    end

    # The row this service would have created already exists, made by the ordinary attach flow.
    test "a file already attached is not attached twice" do
      node = file("bracket.stl")
      @project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      assert_equal 0, intake.attached
      assert_equal 1, @project.file_attachments.count
    end

    # THE RACE TASK 9a EXISTS TO CLOSE, driven end to end. The test above covers the NON-concurrent
    # case: a row that already existed by the time #attach's read ran. This one covers the case
    # that read-then-reject cannot, by construction: a second writer that inserts the SAME
    # (user, attachable_type, attachable_id, node_id) tuple AFTER #attach has already read "not
    # attached yet" but BEFORE #attach's own insert_all lands. Before the migration's unique index
    # existed, that window let a second row through silently — no constraint anywhere stopped it.
    #
    # WHAT THIS TEST CAN AND CANNOT DISCRIMINATE, recorded because it is not obvious and would
    # otherwise be assumed wrong the first time someone reverted `unique_by:` and watched this stay
    # green. Bare `Model.insert_all(rows)` — no `on_duplicate:`, no `unique_by:` — is NOT "insert,
    # raise on conflict": ActiveRecord::Relation#insert_all hardcodes `on_duplicate: :skip`, and
    # find_unique_index_for resolves an unspecified `unique_by:` against the model's PRIMARY KEY,
    # which (for an all-new batch with no `id` set) always matches trivially — so it emits a bare,
    # UNTARGETED `ON CONFLICT DO NOTHING`, which Postgres and SQLite both apply to ANY unique
    # constraint violation on the insert, not just ours. Measured directly against this table
    # (`bin/rails runner`, both with and without `unique_by:`): once the migration's index exists,
    # the NO-RAISE / EXACTLY-ONE-ROW assertions below hold EITHER WAY. So this test's row-count and
    # assert_nothing_raised assertions are pinned to the MIGRATION (Part A), not to this method's
    # `unique_by:` (Part B) — reverting just the `unique_by:` argument leaves them green.
    #
    # THE KWARGS ASSERTION AT THE BOTTOM IS THE ONE THAT PINS PART B, by asserting on the call
    # itself rather than only its emergent effect: that #attach names `idx_maker_file_attachments_
    # unique` explicitly rather than leaning on the untargeted default. That is not cosmetic —
    # naming the index scopes the swallowed conflict to exactly this tuple, so a DIFFERENT, future
    # unique constraint on this table that a race also violated would still raise instead of being
    # silently absorbed by a blanket DO NOTHING. Confirmed by inspecting the emitted SQL directly:
    # unique_by: produces `ON CONFLICT ("user_id","attachable_type","attachable_id","node_id") DO
    # NOTHING`; its absence produces `ON CONFLICT DO NOTHING` with no column list at all.
    #
    # HOOKED AT insert_all, NOT A REAL SECOND THREAD, and that is deliberate. A real thread cannot
    # GUARANTEE the interleaving lands inside the window on every run — a race test that only
    # sometimes exercises the race is worse than none, since it reports green on a coin flip.
    # Hooking the one call site #attach makes to insert_all — the exact place a concurrent
    # committer's row must already have landed for the skip to have anything to skip — makes the
    # interleaving happen on every run, deterministically, while every OTHER line of #attach (the
    # read, the reject, the row-building) runs completely unmodified: this is the real code path,
    # not a rewritten stand-in for it.
    #
    # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` does not exist in
    # this suite (requiring it is a LoadError) — the same constraint with_broken_move above answers
    # by defining a singleton method rather than reaching for a mocking library.
    test "#attach is safe under a concurrent insert into the same race window" do
      node = file("bracket.stl")

      raced = false
      captured_kwargs = nil
      original_insert_all = Maker::FileAttachment.method(:insert_all)
      Maker::FileAttachment.define_singleton_method(:insert_all) do |rows, **kwargs|
        captured_kwargs = kwargs
        unless raced
          raced = true
          # THE CONCURRENT WRITER — the identical tuple #attach is about to insert, landed by a
          # SEPARATE statement first. Stands in for any of the six other writers CLAUDE.md counts
          # (AttachToProject#call, AttachToProject#attach_bundle, Projects::UploadsController,
          # Models::AttachmentsController, CurrentProject#attach_addon_files_to_current_project,
          # Projects::EntryPhotosController) or a second ProjectIntake sweep running concurrently.
          row = rows.first
          Maker::FileAttachment.create!(user_id: row[:user_id], attachable_type: row[:attachable_type],
                                        attachable_id: row[:attachable_id], node_id: row[:node_id],
                                        role: "other")
        end
        original_insert_all.call(rows, **kwargs)
      end

      begin
        result = nil
        # assert_nothing_raised takes NO message argument (ActiveSupport::Testing::Assertions) —
        # unlike most assertions here, it is arity 0 plus a block.
        assert_nothing_raised do
          result = intake
        end
        assert_equal 1, @project.file_attachments.where(node_id: node.node_id).count,
                     "exactly one row must survive the race — not two, and not zero"
        assert_equal 1, result.attached,
                     "the sweep still reports its own attempt; the race is invisible to this count"
        assert_equal :index_maker_file_attachments_uniqueness, captured_kwargs[:unique_by],
                     "#attach must name the index explicitly, not lean on insert_all's untargeted " \
                     "default — see this test's own comment for why that is not merely cosmetic"
      ensure
        Maker::FileAttachment.singleton_class.send(:remove_method, :insert_all)
      end
    end

    test "the role is derived per file, not copied" do
      stl = file("bracket.stl")
      pdf = file("guide.pdf")
      lbrn = file("box.lbrn2")
      intake
      assert_equal "model", roles[stl.node_id]
      assert_equal "instructions", roles[pdf.node_id]
      assert_equal "laser", roles[lbrn.node_id]
    end

    # --- the folder is READ, never ensured ---------------------------------------

    # THE SIDE-EFFECT BUG THIS DESIGN IS WRITTEN TO AVOID. Projects::AttachmentsController#relocate
    # shipped exactly this: an endpoint that created Projects/<slug> as a side effect of being
    # asked a question. A SWEEP doing it would create a folder for every project that never had one.
    test "a project with no folder is skipped and no folder is created" do
      bare = @user.maker_projects.create!(name: "Nothing Yet")
      before = @user.nodes.count
      result = Maker::ProjectIntake.for_project(user: @user, project: bare)
      assert_equal :no_folder, result.status
      assert_equal 0, result.attached
      assert_equal before, @user.nodes.count, "a sweep must not create the project's folder"
      assert_nil bare.reload.folder_node_id
    end

    test "a project whose folder was deleted is skipped, not recreated" do
      @folder.update!(deleted: true)
      before = @user.nodes.present.count
      assert_equal :no_folder, intake.status
      assert_equal before, @user.nodes.present.count
    end

    # An archived project's folder is still its folder. Skipping it would let files pile up in it
    # permanently unattached, silently.
    test "an archived project is still swept" do
      @project.archive!
      file("bracket.stl")
      assert_equal 1, intake.attached
    end

    # --- edge cases: a cycle, a symlink, dry-run, a folder_node_id that isn't a dir -------------

    # THE GUARD THIS EXERCISES. A literal "A and B are each other's parent" pair does NOT reach it:
    # each node has ONE parent_node_id, so closing that edge would disconnect the pair from @folder
    # and the walk would never enter it. Routing the cycle back through the PROJECT FOLDER ITSELF —
    # folder -> dir_a -> dir_b -> folder — is what actually re-presents an already-`seen` node_id to
    # the visited check. Without that check firing first, this would spin (MAX_DEPTH.times still
    # bounds the iteration count, but the visited set is what stops the file from being collected
    # more than once via repeated re-expansion — and before Task 9a's unique index, a double-collect
    # would have silently written two rows for one file; today it would instead cost a second,
    # database-skipped insert attempt for the same tuple — see #owning_project's comment, just above
    # this class in app/services/maker/project_intake.rb, for the same contrast worked out in full).
    test "a cycle through the project folder terminates and attaches the file inside once" do
      dir_a = dir("dir_a")
      dir_b = dir("dir_b", parent: dir_a.node_id)
      @folder.update!(parent_node_id: dir_b.node_id)
      node = file("bracket.stl", parent: dir_a.node_id)

      result = intake
      assert_equal 1, result.attached
      assert_equal 1, @project.file_attachments.where(node_id: node.node_id).count
    end

    # `node.file?` / `elsif node.dir?` silently drops `kind: "symlink"` today — deliberately, per
    # subtree_files' comment. Pinned so a future `case node.kind` refactor that defaults to
    # "treat as file" regresses loudly instead of silently.
    test "a symlink is never attached" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "shortcut", kind: "symlink",
                          parent_node_id: @folder.node_id)
      assert_equal 0, intake.attached
    end

    # Live code, not scaffolding: Task 12's rake task depends on a preview that actually previews.
    test "dry_run reports the count but writes nothing" do
      file("bracket.stl")
      result = Maker::ProjectIntake.for_project(user: @user, project: @project, dry_run: true)
      assert_equal 1, result.attached
      assert_equal 0, @project.file_attachments.count
    end

    # live_folder's explicit `kind: "dir"` filter is what makes this :no_folder rather than a crash
    # or a false attach — the existing tombstone test exercises the `present` half of the same
    # find_by, not this one.
    test "a folder_node_id pointing at a file, not a dir, reads as no_folder" do
      stray = file("not-a-folder.stl", parent: nil)
      @project.update!(folder_node_id: stray.node_id)

      result = intake
      assert_equal :no_folder, result.status
      assert_equal 0, result.attached
    end

    # THE SILENT-TRUNCATION GAP. Without a warning, a legitimately deep (non-cyclic) tree past
    # MAX_DEPTH is indistinguishable from a complete sweep: `status` reads :ok either way. Builds a
    # chain of exactly MAX_DEPTH directories below the folder, so the file one level past that is
    # never reached (see MAX_DEPTH's comment for why) — and asserts on the LOGGED TEXT rather than
    # mocking Rails.logger, since Object#stub does not exist in this suite (minitest 6 dropped
    # minitest/mock). A real Logger writing into a StringIO needs no mock library.
    test "a tree deeper than MAX_DEPTH is truncated, logs a warning, and still reports :ok" do
      deepest = Maker::ProjectIntake::MAX_DEPTH.times.inject(@folder.node_id) do |parent, i|
        dir("level#{i}", parent:).node_id
      end
      buried = file("buried.stl", parent: deepest)

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      result = begin
        intake
      ensure
        Rails.logger = original_logger
      end

      assert_equal :ok, result.status
      assert_equal 0, result.attached, "the file one level past MAX_DEPTH must not be found"
      assert_empty roles.slice(buried.node_id)
      assert_match @project.slug, log.string
      assert_match "1 directory left unvisited", log.string
    end

    # --- the filing step ---------------------------------------------------------

    def parent_name(node) = @user.nodes.find_by(node_id: node.reload.parent_node_id)&.name

    test "a loose file at the root is filed into its category folder" do
      node = file("panel.svg")
      result = intake
      assert_equal 1, result.moved
      assert_equal "design", parent_name(node)
    end

    test "each category gets its own folder, created only when needed" do
      svg = file("panel.svg")
      nc = file("pocket.nc")
      intake
      assert_equal "design", parent_name(svg)
      assert_equal "cnc", parent_name(nc)
      # LAZY: only the two folders that were needed exist, not all nine.
      made = @user.nodes.present.where(parent_node_id: @folder.node_id, kind: "dir").pluck(:name)
      assert_equal %w[cnc design], made.sort
    end

    # COVERAGE, NOT A KNOWN BUG: LibraryFolder#ensure_segment find-or-creates each segment, so this
    # is safe today. It is the case a future change to folder creation would break first — two
    # files racing to create "design" in the same sweep must still land in ONE folder, not two
    # identically-named ones.
    test "two loose files that need the same new folder both land in the one folder" do
      svg1 = file("panel.svg")
      svg2 = file("plate.svg")
      result = intake
      assert_equal 2, result.moved
      assert_equal "design", parent_name(svg1)
      assert_equal "design", parent_name(svg2)
      assert_equal svg1.reload.parent_node_id, svg2.reload.parent_node_id
      made = @user.nodes.present.where(parent_node_id: @folder.node_id, kind: "dir").pluck(:name)
      assert_equal %w[design], made
    end

    # ROOT = INBOX. A file the user filed by hand — even "wrong" — is never touched again.
    test "a file already in a subfolder is left exactly where it is" do
      sub = dir("cnc")
      node = file("panel.svg", parent: sub.node_id) # svg in cnc/ is "wrong", and that is allowed
      result = intake
      assert_equal 0, result.moved
      assert_equal "cnc", parent_name(node)
    end

    test "filing is idempotent — a second run moves nothing" do
      file("panel.svg")
      assert_equal 1, intake.moved
      assert_equal 0, intake.moved
    end

    test "the node_id survives the move, so attachments keep pointing at it" do
      node = file("panel.svg")
      intake
      assert @project.file_attachments.exists?(node_id: node.node_id)
      assert_equal node.node_id, @user.nodes.find_by(name: "panel.svg").node_id
    end

    test "a directory at the root is not moved" do
      d = dir("loose")
      assert_equal 0, intake.moved
      assert_equal @folder.node_id, d.reload.parent_node_id
    end

    # --- .destination_for: where a file WILL end up, asked BEFORE it is written ------------------
    #
    # THE GAP THIS CLOSES (CLAUDE.md §12 item 11, and the bug that prompted it): a door's collision
    # check looks at the folder the user PICKED, and the sweep's looks at the CATEGORY folder it
    # files into. Those are different folders, so a re-save slips between them — the first copy has
    # already moved to design/, leaving the root vacant, so the door accepts a name the sweep then
    # cannot place. Reproduced: harbor-number-v4.svg, saved twice, stranded at the project root
    # through every later sweep.
    #
    # ANSWERS nil FOR ANYTHING THAT IS NOT A PROJECT FOLDER'S OWN ROOT, which is the same question
    # §14f's sort rule asks and the same one ProjectIntakeJob.nudge asks. A save into an ordinary
    # library folder has no category destination and must keep today's behaviour exactly.
    test "destination_for names the category folder a file will be filed into" do
      d = Maker::ProjectIntake.destination_for(user: @user, parent_node_id: @folder.node_id,
                                               name: "panel.svg")
      assert_equal "design", d.folder
      assert_equal @project.id, d.project.id
      assert_nil d.occupied_by, "nothing is in design/ yet"
    end

    test "destination_for reports the file already occupying that name" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "design" ])
      taken = file("panel.svg", parent: sub.node_id)

      d = Maker::ProjectIntake.destination_for(user: @user, parent_node_id: @folder.node_id,
                                               name: "panel.svg")
      assert_equal taken.node_id, d.occupied_by&.node_id
    end

    # THE CATEGORY FOLDER NEED NOT EXIST YET, and asking must not create it — the same rule
    # #live_folder follows for Project#ensure_library_folder!. A read that creates directories as a
    # side effect of being asked is the bug Projects::AttachmentsController#relocate shipped.
    test "destination_for creates nothing" do
      before = @user.nodes.count
      Maker::ProjectIntake.destination_for(user: @user, parent_node_id: @folder.node_id,
                                           name: "part.stl")
      assert_equal before, @user.nodes.count
    end

    test "destination_for answers nil outside a project folder root" do
      sub = dir("design")
      assert_nil Maker::ProjectIntake.destination_for(user: @user, parent_node_id: sub.node_id,
                                                      name: "panel.svg")
      assert_nil Maker::ProjectIntake.destination_for(user: @user, parent_node_id: nil,
                                                      name: "panel.svg")
    end

    # THE THREE EXISTING RULES MUST NOT BE BYPASSED BY THIS THIRD DOOR. Maker::AttachToProject's
    # header records #relocate being written below all of them and gutting a model bundle while
    # reporting success.
    test "a model's file is not filed — the bundle rule still applies" do
      model = @user.maker_models.create!(title: "Widget")
      node = file("widget.stl")
      model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      result = intake
      assert_equal 0, result.moved
      assert_equal [ [ "widget.stl", :model_bundle ] ], result.skips
      assert_equal @folder.node_id, node.reload.parent_node_id
    end

    # ...BUT :attached_elsewhere IS NOT ONE OF THE THREE THAT TRANSFERS, and this test asserts the
    # OPPOSITE of what it asserted before (it required the file to stay at the root). The rule's own
    # justification is positional — Maker::AttachToProject's header: "another project already claims
    # it, and a file should not be YANKED OUT OF THE FOLDER THAT PROJECT PUT IT IN" — and it was
    # written for #call/#relocate, where the destination is THIS project's folder and the source may
    # well be the other project's. #place's move goes from this project's OWN folder to a category
    # subfolder beneath it — resolved under `folder_node_id`, so the folder need not be named after
    # the slug (Maker::ProjectDiscovery adopts folders that are not):
    # the file is already inside this project's own folder, so there is no other project's folder to
    # yank it out of and the rule's precondition cannot hold. Nothing about the other project's view
    # changes either — node_id never changes across a move (Maker::MoveNode's stated promise), so its
    # attachment keeps pointing at the same file.
    #
    # IT WAS SILENT AND PERMANENT, which is why it is worth a test rather than a comment: the file
    # sat at the root through every 15-minute sweep forever, with a `skips` entry only
    # `rake projects:organize` prints. Reachable without doing anything unusual —
    # CurrentProject#attach_addon_files_to_current_project attaches an addon's output to whatever
    # project is CURRENT, regardless of which folder the save dialog wrote it into, so one addon save
    # into another project's folder made that file permanently unsortable.
    #
    # THE OTHER TWO RULES ARE UNCHANGED, deliberately: :not_a_file and :model_bundle still refuse
    # here (see the test above, which still passes). Only the arm whose stated reason is about the
    # SOURCE folder is scoped, and it is scoped at Maker::AttachToProject#refusal_for — one policy
    # home — rather than by this class second-guessing a symbol it was handed.
    test "a file another project also claims is still filed — the move stays inside this project's own folder" do
      other = @user.maker_projects.create!(name: "Bench")
      node = file("shared.stl")
      other.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      result = intake
      assert_equal 1, result.moved
      assert_empty result.skips
      assert_equal "models", parent_name(node)
      assert other.file_attachments.exists?(node_id: node.node_id),
             "the other project's attachment must survive the move — node_id never changes"
    end

    # The rule still applies where its own reason DOES hold: a move that would take the file out of
    # another project's folder is still refused. This is the half that must not regress.
    test "a file another project claims is still not relocated INTO this project by the attach door" do
      other = @user.maker_projects.create!(name: "Bench")
      other_folder = other.ensure_library_folder!(@user)
      node = file("shared.stl", parent: other_folder.node_id)
      other.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")

      policy = Maker::AttachToProject.new(user: @user, project: @project)
      assert_equal :attached_elsewhere, policy.refusal_for(node)
      assert_equal other_folder.node_id, node.reload.parent_node_id
    end

    # A collision leaves the file at the root AND keeps the attachment — the attach is the durable
    # half, the move is best-effort (Maker::AttachToProject's rule, applied here).
    test "a name already taken in the destination leaves the file at the root, still attached" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "design" ])
      file("panel.svg", parent: sub.node_id)
      loose = file("panel.svg")
      result = intake
      assert_equal 0, result.moved
      assert_equal 1, result.skipped
      assert_equal [ [ "panel.svg", :conflict ] ], result.skips
      assert_equal @folder.node_id, loose.reload.parent_node_id
      assert @project.file_attachments.exists?(node_id: loose.node_id),
             "the attach is durable — a failed move must not cost the reference"
    end

    test "one collision does not stop the rest of the sweep" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "design" ])
      file("panel.svg", parent: sub.node_id)
      file("panel.svg")          # collides
      ok = file("pocket.nc")     # must still be filed
      result = intake
      assert_equal 1, result.moved
      assert_equal 1, result.skipped
      assert_equal [ [ "panel.svg", :conflict ] ], result.skips
      assert_equal "cnc", parent_name(ok)
    end

    # THE LOG IS THE AUDIT TRAIL for a skip, same as it is for a MAX_DEPTH truncation above — a
    # real Logger writing into a StringIO, not a mock (Object#stub does not exist in this suite).
    # Pinned on #collision specifically so each rescue clause's route through #skip is verified on
    # its own: the moved/skipped/skips counts above would already catch a clause that forgot to
    # call #skip and returned something else, but only the log content proves the warn actually
    # fires with the file, the project and the reason in it.
    test "a skipped file logs a warning naming the file, the project and the reason" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "design" ])
      file("panel.svg", parent: sub.node_id)
      file("panel.svg") # collides

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      begin
        intake
      ensure
        Rails.logger = original_logger
      end

      assert_match "panel.svg", log.string
      assert_match @project.slug, log.string
      assert_match "Maker::MoveNode::Collision", log.string
    end

    # REGRESSION GUARD. Maker::MoveNode::InvalidName is a real, reachable outcome on this path, not
    # just adversarial input — before #place rescued it, this exact scenario raised out of
    # Maker::ProjectIntake.for_project uncaught, aborting the whole project's sweep instead of
    # returning a Result. `Node` validates only presence (see app/models/node.rb) — no length or
    # shape check — so a name like this can already be sitting in `nodes` from a door that never
    # runs MoveNode#leaf!, and an ordinary CJK filename from a Windows client is enough to trigger
    # it (NTFS counts UTF-16 units; see MoveNode::MAX_NAME_BYTES's comment) — no adversary required.
    test "a name too long to move is skipped, logged, and does not abort the rest of the sweep" do
      bad = file(("a" * 300) + ".svg")
      ok = file("pocket.nc")

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      result = begin
        intake
      ensure
        Rails.logger = original_logger
      end

      assert_equal 1, result.moved
      assert_equal 1, result.skipped
      assert_equal [ [ bad.name, :bad_name ] ], result.skips
      assert_equal "cnc", parent_name(ok), "a bad name must not abort the rest of the sweep"
      assert_match @project.slug, log.string
      assert_match "not a valid file name", log.string
    end

    test "move: false attaches without filing anything" do
      node = file("panel.svg")
      result = Maker::ProjectIntake.for_project(user: @user, project: @project, move: false)
      assert_equal 1, result.attached
      assert_equal 0, result.moved
      assert_equal @folder.node_id, node.reload.parent_node_id
    end

    # --- dry run -----------------------------------------------------------------

    test "a dry run writes nothing at all — not even the attachment rows" do
      node = file("panel.svg")
      result = Maker::ProjectIntake.for_project(user: @user, project: @project, dry_run: true)
      assert_equal 1, result.attached
      assert_equal 1, result.moved
      assert_equal [ [ "panel.svg", "design" ] ], result.plan
      assert_equal 0, @project.file_attachments.count, "a dry run must write no attachment rows"
      assert_equal @folder.node_id, node.reload.parent_node_id
      assert_not @user.nodes.present.exists?(parent_node_id: @folder.node_id, kind: "dir"),
                 "a dry run must not create the category folder either"
    end

    # --- an unreachable library --------------------------------------------------

    # A backend whose `move` always raises, counting attempts. Hand-rolled rather than Object#stub:
    # minitest 6 DROPPED minitest/mock, so `stub` does not exist in this suite (requiring it is a
    # LoadError). Modelled on with_broken_move in attach_auto_move_test.rb.
    #
    # `port_writable? = true` sends Maker::MoveNode through the port door, straight into `move`.
    #
    # THE fake DEFINES mkdir, and that is new as of Stage 2 (Task 3): Maker::LibraryFolder#ensure_segment
    # used to short-circuit on an already-catalogued dir BEFORE ever reaching the port, so a fake with
    # no mkdir at all got away with it as long as every test below pre-seeded the destination folder.
    # ensure_segment no longer has a short-circuit of its own — it calls FileLayer.current.mkdir
    # UNCONDITIONALLY and leans on the adapter's OWN idempotence (CLAUDE.md 14a) — so this fake must
    # answer mkdir too, or every test here dies on NoMethodError before `move` is ever reached.
    #
    # The seeding requirement does NOT go away, it just changes shape: this mkdir does not create
    # anything (a fake standing in for "the backend is unreachable" has no store to create a
    # directory in) — it only FINDS a dir already in the catalog by (parent_node_id, name), i.e. the
    # SAME identity Chunk#mkdir's idempotence check uses. `find_by!` (bang), not `find_by`, on
    # purpose: a test that forgot to call seed_folder must still fail loudly, on RecordNotFound
    # instead of the old NoMethodError, rather than silently answer something #place accepts.
    #
    # `fail_after:` lets a caller ask for N clean successes before the raising starts. The
    # succeed-then-abort test below needs the FIRST file to move for real — #place's return value
    # is the `dest` string regardless of what `move` answers, so a fake that always raises can never
    # tell "moved/plan correctly kept" apart from "wrongly zeroed on abort". Default 0 keeps every
    # existing caller's "raises from the very first attempt" behaviour unchanged.
    def with_broken_move(error_class, fail_after: 0)
      attempts = 0
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      broken.define_singleton_method(:mkdir) do |user, parent_node_id: nil, name: nil|
        node = user.nodes.present.find_by!(parent_node_id:, name:, kind: "dir")
        FileLayer::FileInfo.new(node_id: node.node_id, name: node.name, kind: node.kind,
                                size: 0, mtime: node.mtime, content_token: nil)
      end
      broken.define_singleton_method(:move) do |*|
        attempts += 1
        raise(error_class, "the backend is having a bad day") if attempts > fail_after
      end
      FileLayer.current = broken
      yield -> { attempts }
    ensure
      FileLayer.reset!
    end

    def seed_folder(name)
      Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, name ])
    end

    # An unmounted NAS fails EVERY move identically, so the honest answer is one abort and one log
    # line — not N skips pretending each was independent.
    test "a FetchError aborts this project's sweep after one attempt, counting the rest skipped" do
      seed_folder("design") # the fake's mkdir only finds; it never creates
      file("a.svg")
      file("b.svg")
      file("c.svg")

      with_broken_move(FileLayer::FetchError) do |attempts|
        result = intake
        assert_equal 0, result.moved
        assert_equal 3, result.skipped
        assert_equal 1, attempts.call, "it must stop after the first FetchError, not try all three"
        assert_equal :ok, result.status
        # THE DETAIL MUST SURVIVE THE ABORT, and every unprocessed file is named — including the
        # one that raised. A count alone would tell an operator three files did not move without
        # telling them which, which is the gap `skips` was added to close.
        assert_equal %i[unavailable unavailable unavailable], result.skips.map(&:last)
        assert_equal %w[a.svg b.svg c.svg], result.skips.map(&:first).sort
      end
    end

    # THE LOG NAMES THE FILES, not just the count — mirroring Library::Reconciler#unreadable_note's
    # "a refusal should diagnose itself". Split from the behaviour test above the same way the
    # :conflict case splits "a name already taken..." from "a skipped file logs a warning...":
    # the counts/skips assertions already prove #file_all's bookkeeping; this proves the warn line
    # itself carries the names, which is a separate fact a passing count could still get wrong.
    test "the abort log names the unavailable files, not just the count" do
      seed_folder("design")
      file("a.svg")
      file("b.svg")
      file("c.svg")

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      begin
        with_broken_move(FileLayer::FetchError) { intake }
      ensure
        Rails.logger = original_logger
      end

      assert_match @project.slug, log.string
      assert_match "FileLayer::FetchError", log.string
      %w[a.svg b.svg c.svg].each { |name| assert_match name, log.string }
    end

    # The attach still happened — it is the durable half and it touches no bytes.
    test "an unreachable library still leaves the attachments behind" do
      seed_folder("design")
      file("a.svg")
      with_broken_move(FileLayer::FetchError) do
        assert_equal 1, intake.attached
      end
      assert_equal 1, @project.file_attachments.count
    end

    # CONTRAST, and it is what proves the two rescues are in different places: a per-file condition
    # must NOT abort the sweep. Both files are attempted.
    test "an UnsupportedOperation is per-file and does not abort the sweep" do
      seed_folder("design")
      file("a.svg")
      file("b.svg")

      with_broken_move(FileLayer::UnsupportedOperation) do |attempts|
        result = intake
        assert_equal 0, result.moved
        assert_equal 2, result.skipped
        assert_equal 2, attempts.call, "a per-file refusal must not stop the file after it"
      end
    end

    # THE GAP A MUTATION FOUND: every FetchError test above has the FIRST file raise, so `moved`
    # is 0 in every one of them — a rescue clause that discarded `moved` and `plan` entirely
    # (returning `[0, skips.size, skips, []]` instead of the real values) would still pass all of
    # them. This is the one that catches it: the fake succeeds ONCE before it raises, so a
    # wrongly-zeroed `moved`/`plan` is the only way this test can fail. Order-independent on
    # purpose — nothing here assumes which of the three files the DB hands back first, only that
    # whichever one was processed before the abort keeps its result and the other two do not.
    test "a move that succeeds once keeps its result when a later file aborts the sweep" do
      seed_folder("design")
      names = %w[a.svg b.svg c.svg]
      names.each { |n| file(n) }

      with_broken_move(FileLayer::FetchError, fail_after: 1) do |attempts|
        result = intake
        assert_equal 1, result.moved, "the abort must not zero out a move that already succeeded"
        assert_equal 1, result.plan.size
        assert_equal 2, result.skipped
        assert_equal 2, attempts.call, "the third file must never be attempted once the abort fires"

        moved_name = result.plan.first.first
        assert_includes names, moved_name
        assert_equal %i[unavailable unavailable], result.skips.map(&:last)
        assert_equal (names - [ moved_name ]).sort, result.skips.map(&:first).sort
      end
    end

    # --- the live_folder memo actually saves a query ------------------------------
    #
    # UNTESTED UNTIL NOW (CLAUDE.md §14e: "Query cost is a property nothing asserts unless you
    # assert it"). The file's one count_queries test ("an over-cap upload costs a small,
    # backlog-independent number of queries", further down) exercises the path where #place never
    # runs at all — it cannot regress on THIS. Someone "simplifying" #live_folder back to a plain
    # find_by would pass every other test in this file.
    #
    # WHY THIS RUNS AGAINST A FAKE PORT RATHER THAN THE REAL SHARE ADAPTER SETUP OTHERWISE
    # INSISTS ON: FileLayer::Share#move (and FileLayer::S3's twin) resolve their destination's
    # storage path via #parent_dir_rel!, which is find_by(node_id:, kind: "dir") — the EXACT SAME
    # SHAPE #live_folder queries. Rails logs SQL with `?` placeholders, never the bound values, so
    # the two calls are BYTE-IDENTICAL text with nothing here able to tell them apart (verified
    # directly, bin/rails runner, both printed side by side). Run this guard against the real
    # share port instead and filing 3 files costs 3 parent_dir_rel! lookups — one per move — ON
    # TOP OF #live_folder's 1, a real and LEGITIMATE cost that has nothing to do with the memo. A
    # text-based filter cannot tell "the memo broke" from "a different query that is SUPPOSED to
    # scale with N happens to read identically" — so this fakes the port's #move, which updates
    # the row directly and never calls #parent_dir_rel! at all, leaving only what ProjectIntake
    # itself asks for to count.
    #
    # MIRRORS with_broken_move ABOVE, DELIBERATELY — same capabilities stub, same defensive
    # find_by! (bang) on mkdir so a test that forgets to pre-seed the category folder fails loudly
    # on RecordNotFound rather than silently reporting a wrong count.
    def with_successful_move
      fake = Object.new
      def fake.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      fake.define_singleton_method(:mkdir) do |user, parent_node_id: nil, name: nil|
        node = user.nodes.present.find_by!(parent_node_id:, name:, kind: "dir")
        FileLayer::FileInfo.new(node_id: node.node_id, name: node.name, kind: node.kind,
                                size: 0, mtime: node.mtime, content_token: nil)
      end
      fake.define_singleton_method(:move) do |user, node_id: nil, new_parent_node_id: nil, new_name: nil|
        user.nodes.present.find_by!(node_id:)
            .update!(parent_node_id: new_parent_node_id, name: new_name)
      end
      FileLayer.current = fake
      yield
    ensure
      FileLayer.reset!
    end

    # THE FILTER IS NARROWER THAN "MENTIONS node_id AND kind", and it has to be — three OTHER
    # queries on this table name both columns in one WHERE clause during an ordinary sweep:
    # Maker::LibraryFolder#ensure_segment's find_by(parent_node_id:, name:, kind: "dir"),
    # Maker::MoveNode#live_dir!'s exists?(node_id:, kind: "dir"), and — on the real share/s3
    # ports, which this test deliberately avoids (see with_successful_move) — #parent_dir_rel!'s
    # own find_by(node_id:, kind: "dir"). Verified directly (bin/rails runner) which of these is
    # unique to #live_folder's shape: only its own starts `SELECT "nodes".*` (ensure_segment's
    # does too, but always alongside `parent_node_id`; live_dir!'s starts `SELECT 1 AS one`, the
    # `.exists?` shape) AND filters `node_id =` AND `kind =`, WITH NO `parent_node_id` alongside
    # it.
    def folder_lookup_count(sql_statements)
      sql_statements.count do |sql|
        sql.match?(/\ASELECT "nodes"\.\* /) &&
          sql.include?(%("nodes"."node_id" = )) &&
          sql.include?(%("nodes"."kind" = )) &&
          !sql.include?(%("nodes"."parent_node_id"))
      end
    end

    # THE GUARD ITSELF. Backend-agnostic on purpose (CLAUDE.md §14e / page_query_budget_test.rb):
    # asserts filing 3 files costs the SAME number of #live_folder lookups as filing 1, never a
    # literal count that would pin one LIBRARY_BACKEND and fail the other two.
    test "the live_folder lookup does not grow with the number of files filed" do
      dir("design", parent: @folder.node_id) # pre-seeded so create_child! never reaches mkdir

      with_successful_move do
        file("solo.svg")
        one = folder_lookup_count(capture_sql {
          Maker::ProjectIntake.for_project(user: @user, project: @project)
        })

        3.times { |i| file("many#{i}.svg") }
        three = folder_lookup_count(capture_sql {
          Maker::ProjectIntake.for_project(user: @user, project: @project)
        })

        # SANITY FIRST (this file's own recorded lesson, "the shape of the walk" above): an empty
        # filter passes an equality trivially without proving it ever saw the query it exists to
        # count.
        assert_operator one, :>=, 1, "sanity: the filter must actually see #live_folder's own query"
        assert_equal one, three,
                     "filing 3 files must cost the SAME number of project-folder lookups as filing " \
                     "1 file — #live_folder's memo, not the file count, is what this measures"
      end
    end

    # --- for_user and the run cap ------------------------------------------------

    test "for_user sweeps every project that has a folder" do
      bench = @user.maker_projects.create!(name: "Bench")
      bench_folder = bench.ensure_library_folder!(@user)
      file("panel.svg")
      file("pocket.nc", parent: bench_folder.node_id)

      run = Maker::ProjectIntake.for_user(user: @user)
      assert_equal :ok, run.status
      assert_equal 2, run.results.size
      assert_equal 2, run.results.sum { |_p, r| r.moved }
    end

    test "for_user skips projects with no folder without creating one" do
      @user.maker_projects.create!(name: "Nothing Yet")
      run = Maker::ProjectIntake.for_user(user: @user)
      assert_equal 1, run.results.size, "a folderless project is not even visited"
    end

    # THE projects.empty? BRANCH — nothing else in this file reaches it, since setup always gives
    # @user one project with a folder. That gap is exactly what let two RunResult.new call sites
    # disagree unnoticed (see the agreement test below): a suite that never visits zero projects
    # cannot catch a bug that only shows up there.
    test "for_user with no folder'd projects at all reports ok and moves nothing" do
      fresh = User.create!(email: "pi-empty-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      run = Maker::ProjectIntake.for_user(user: fresh)
      assert_equal :ok, run.status
      assert_empty run.results
      assert_equal 0, run.inbox_total
    end

    # THE BUG THIS PINS: for_user used to construct its RunResult in two places — one hardcoded
    # `status: :ok` for zero projects, the other computed `refused` from `inbox_total > cap` for
    # everyone else. "Zero projects" and "one project with an empty inbox" are the SAME real
    # situation — nothing to file — so under a cap that refuses even zero (any negative number,
    # since a count is never negative) they must answer identically. They did not: the hardcoded
    # branch always said :ok no matter what cap was passed. Collapsing to one construction site
    # fixed it; this is what would catch a regression back to two.
    test "a zero-projects run and a zero-loose-files run agree under a cap that refuses zero" do
      fresh = User.create!(email: "pi-empty-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      zero_projects = Maker::ProjectIntake.for_user(user: fresh, cap: -1)
      zero_inbox = Maker::ProjectIntake.for_user(user: @user, cap: -1) # @project has a folder, empty

      assert_equal :refused_too_many_moves, zero_projects.status
      assert_equal zero_inbox.status, zero_projects.status
    end

    # An archived project's folder is still its folder — for_project already proves this on its own
    # ("an archived project is still swept" above). This pins the same rule at the for_user level,
    # where a future `.active` scope tacked onto the projects query would look like a reasonable
    # cleanup and would silently stop organizing anything archived.
    test "for_user still sweeps an archived project" do
      @project.archive!
      file("panel.svg")
      run = Maker::ProjectIntake.for_user(user: @user)
      assert_equal 1, run.results.size
      assert_equal 1, run.results.sum { |_p, r| r.moved }
    end

    # THE CAP'S DESIGN, AND THE HALF A TEST THAT ONLY COUNTS MOVES WOULD MISS: over the cap,
    # NOTHING MOVES AND EVERYTHING STILL ATTACHES.
    test "over the cap nothing is filed but everything is still attached" do
      3.times { |i| file("p#{i}.svg") }
      run = Maker::ProjectIntake.for_user(user: @user, cap: 2)
      assert_equal :refused_too_many_moves, run.status
      assert_equal 3, run.inbox_total
      assert_equal 2, run.cap
      assert_equal 0, run.results.sum { |_p, r| r.moved }
      assert_equal 3, run.results.sum { |_p, r| r.attached },
                    "the attach step writes no bytes, so the cap has no reason to withhold it"
      assert_equal 3, @project.file_attachments.count
    end

    # Checked BEFORE the first move, not enforced by stopping partway: a partial sweep would pace
    # the work into batches and file the whole library anyway, 500 at a time, guarding nothing.
    test "the cap moves nothing at all, rather than moving up to the cap" do
      3.times { |i| file("p#{i}.svg") }
      Maker::ProjectIntake.for_user(user: @user, cap: 2)
      assert_equal 0, @user.nodes.present.where(parent_node_id: @folder.node_id, kind: "dir").count,
                   "not one move happened, so not one category folder was created"
    end

    test "at exactly the cap it proceeds" do
      2.times { |i| file("p#{i}.svg") }
      run = Maker::ProjectIntake.for_user(user: @user, cap: 2)
      assert_equal :ok, run.status
      assert_equal 2, run.results.sum { |_p, r| r.moved }
    end

    # The cap counts across the RUN, not per project — a per-project cap would bound the wrong thing.
    test "the cap sums every project's inbox" do
      bench = @user.maker_projects.create!(name: "Bench")
      bench_folder = bench.ensure_library_folder!(@user)
      2.times { |i| file("a#{i}.svg") }
      2.times { |i| file("b#{i}.svg", parent: bench_folder.node_id) }

      run = Maker::ProjectIntake.for_user(user: @user, cap: 3)
      assert_equal :refused_too_many_moves, run.status
      assert_equal 4, run.inbox_total
    end

    # A dry run must never refuse: seeing the number is the entire reason to run one.
    test "a dry run reports over the cap instead of refusing" do
      3.times { |i| file("p#{i}.svg") }
      run = Maker::ProjectIntake.for_user(user: @user, cap: 1, dry_run: true)
      assert_equal :ok, run.status
      assert_equal 3, run.results.sum { |_p, r| r.moved }
    end

    # READ PER CALL, never frozen at boot: the log line names this variable as the way out, and a
    # boot-frozen value makes that advice false in a running process and unreachable from a test —
    # which is how an escape hatch rots shut (Library::Reconciler#max_delete_pct's recorded lesson).
    test "PROJECT_ORGANIZE_MAX_MOVES is honored per call" do
      3.times { |i| file("p#{i}.svg") }
      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = "1"
      begin
        assert_equal 1, Maker::ProjectIntake.max_moves
        assert_equal :refused_too_many_moves, Maker::ProjectIntake.for_user(user: @user).status
      ensure
        ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
      end
    end

    test "the default cap is 500" do
      assert_equal 500, Maker::ProjectIntake::MAX_MOVES
      assert_equal 500, Maker::ProjectIntake.max_moves
    end

    # --- the EAGER cap (Task 11 Part A) --------------------------------------------
    #
    # A separate, much smaller cap for the ONE caller that runs INSIDE a web request (for_node,
    # below) rather than an unattended background job (for_user/the periodic sweep, above). Named
    # "eager" (the eager nudge FilesController drives), deliberately NOT "sync" -- this cap has
    # nothing to do with Capabilities#syncable?. See EAGER_MAX_MOVES's comment in project_intake.rb
    # for the full argument; these tests exist to PROVE the two caps never leak into each other,
    # not just assert it in a comment.
    #
    # THIS COMMENT USED TO SAY THE CAP "applies identically on all three backends", which was true
    # of the code and wrong about the world -- FileLayer::S3#move is three sequential network calls
    # per file, so 25 eager moves is 75 S3 round-trips inside one browser request. The default is
    # now backend-aware; the tests below pin both halves and the ENV override that outranks them.

    test "PROJECT_ORGANIZE_EAGER_MAX_MOVES is honored per call" do
      prior = ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = "3"
      begin
        assert_equal 3, Maker::ProjectIntake.eager_max_moves
      ensure
        ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = prior
      end
    end

    test "the default eager cap is a low-tens number, well under MAX_MOVES" do
      assert_equal 25, Maker::ProjectIntake::EAGER_MAX_MOVES
      assert_equal 25, Maker::ProjectIntake.eager_max_moves
      assert_operator Maker::ProjectIntake::EAGER_MAX_MOVES, :<, Maker::ProjectIntake::MAX_MOVES
    end

    # The S3 default is LOWER, because one move there is a HEAD + a COPY + a DELETE — three
    # sequential network calls — so the same cap buys three times the round-trips inside a request
    # a browser is waiting on. Pinned per backend rather than asserted once, because the whole
    # point of this change is that the number is NOT the same everywhere.
    # SETS FileLayer.current DIRECTLY rather than pin_file_layer_backend, because that helper only
    # sets LIBRARY_BACKEND and the real adapters refuse to build without their own env
    # (LIBRARY_PATH / the five LIBRARY_S3_*). The cap asks the adapter's CLASS and nothing else, so
    # an adapter instance is the whole precondition — no bucket and no directory are ever touched.
    def with_adapter(adapter)
      FileLayer.current = adapter
      yield
    ensure
      FileLayer.reset!
    end

    def s3_adapter
      FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                        secret_access_key: "sk", prefix: "library")
    end

    test "the eager cap drops on s3, where one move is three network calls" do
      with_adapter(s3_adapter) { assert_equal 5, Maker::ProjectIntake.eager_max_moves }

      assert_operator Maker::ProjectIntake::EAGER_MAX_MOVES_S3, :<,
                      Maker::ProjectIntake::EAGER_MAX_MOVES
    end

    test "share keeps the chunk default — only s3 pays three calls per move" do
      Dir.mktmpdir do |dir|
        with_adapter(FileLayer::Share.new(root: dir)) do
          assert_equal 25, Maker::ProjectIntake.eager_max_moves
        end
      end
    end

    # An operator who has set the variable keeps exactly what they set, on EVERY backend — the
    # backend-aware value is a DEFAULT, not a ceiling imposed over the override.
    test "the ENV override still outranks the backend-aware default on s3" do
      prior = ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = "40"
      begin
        assert_equal 40, Maker::ProjectIntake.eager_max_moves
      ensure
        ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = prior
      end
    end

    # --- for_node ----------------------------------------------------------------

    test "for_node files a file dropped at a project root" do
      node = file("panel.svg")
      result = Maker::ProjectIntake.for_node(user: @user, node:)
      assert_equal 1, result.moved
      assert_equal "design", parent_name(node)
    end

    # The upload chooser can target a category subfolder directly, so the project is one hop up.
    test "for_node resolves the project from inside a category subfolder" do
      sub = dir("design")
      node = file("panel.svg", parent: sub.node_id)
      result = Maker::ProjectIntake.for_node(user: @user, node:)
      assert_not_nil result
      assert_equal 1, result.attached
      assert_equal "design", parent_name(node), "already filed — it must not move again"
    end

    test "for_node answers nil for a file outside every project folder" do
      node = file("stray.stl", parent: nil)
      assert_nil Maker::ProjectIntake.for_node(user: @user, node:)
    end

    test "for_node answers nil when the user has no project folders" do
      other = User.create!(email: "pin-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      node = other.nodes.create!(node_id: SecureRandom.uuid, name: "a.svg", kind: "file")
      assert_nil Maker::ProjectIntake.for_node(user: other, node:)
    end

    # THE HOLE THIS CLOSES, UNCHANGED BY THE EAGER/PERIODIC SPLIT BELOW: without a cap-check of its
    # own, for_node would file an over-cap project's backlog anyway, one eager upload at a time --
    # each individual call would see only the one new file it is attaching, never the pile already
    # sitting there, unless it re-counts the WHOLE inbox before moving anything. It does.
    #
    # USES THE EAGER CAP, NOT THE PERIODIC ONE (Task 11 Part A) -- for_node is the entry point that
    # runs INSIDE a web request, so PROJECT_ORGANIZE_EAGER_MAX_MOVES bounds it; PROJECT_ORGANIZE_
    # MAX_MOVES (for_user's cap) has no effect on it at all. See the independence tests below for
    # proof, not just this comment's say-so.
    test "for_node respects the eager cap, so a large backlog stays attach-only" do
      3.times { |i| file("p#{i}.svg") }
      node = file("trigger.svg")
      prior = ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = "2"
      begin
        result = Maker::ProjectIntake.for_node(user: @user, node:)
        assert_equal 0, result.moved
        assert_equal 4, result.attached, "the attach half still runs, as it does for a whole run"
      ensure
        ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = prior
      end
    end

    test "under the eager cap, for_node both attaches and files" do
      3.times { |i| file("p#{i}.svg") }
      node = file("trigger.svg")
      prior = ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = "10"
      begin
        result = Maker::ProjectIntake.for_node(user: @user, node:)
        assert_equal 4, result.attached
        assert_equal 4, result.moved
      ensure
        ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = prior
      end
    end

    # THE MEASURED IMPROVEMENT ITSELF, NOT JUST THAT A CAP EXISTS. Before this cap, a request that
    # landed in a project already holding 200 loose files paid for filing all 201 of them inline: a
    # `Maker::MoveNode` call per file, measured directly against this code at 2,425 queries and
    # ~340 ms on local SQLite with zero network latency (a runner script mirroring exactly this
    # setup, before Part A existed) -- CHUNK-MODE METADATA COST ONLY; see EAGER_MAX_MOVES's comment
    # for why S3 and chunk-under-Postgres-contention are NOT covered by this number. Over the eager
    # cap, the whole file_all loop is skipped — the remaining cost is the two fixed-size steps: the
    # inbox COUNT and the bulk attach (one pluck + one insert_all, never one query per file). The
    # bound below is deliberately loose (real cost is under 10) so ordinary drift in the attach path
    # cannot make this flaky; what it must catch is the shape coming back — a regression that lets
    # filing run anyway would blow through 30 by two orders of magnitude, not by a little.
    test "an over-cap upload costs a small, backlog-independent number of queries" do
      200.times { |i| file("loose#{i}.svg") }
      node = file("just_uploaded.svg")

      n = count_queries { Maker::ProjectIntake.for_node(user: @user, node:) }

      assert_operator n, :<, 30,
        "an over-the-eager-cap intake must not scale with backlog size (got #{n} queries for 201 " \
        "loose files -- the pre-Part-A shape cost 2,425 for the same setup)"
    end

    # PROOF, NOT ASSERTION, THAT THE TWO CAPS ARE INDEPENDENT -- a comment saying so is exactly the
    # kind of claim that silently rots the moment someone "simplifies" the two methods back into
    # one shared cap. Both directions: setting EITHER variable must leave the OTHER method's
    # behaviour alone.
    test "the periodic cap does not bound for_node" do
      4.times { |i| file("p#{i}.svg") }
      node = file("trigger.svg")
      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      # Far below the 5-file inbox -- if for_node read this variable at all, it would refuse to file.
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = "1"
      begin
        result = Maker::ProjectIntake.for_node(user: @user, node:)
        assert_equal 5, result.moved, "for_node must not be bounded by PROJECT_ORGANIZE_MAX_MOVES"
      ensure
        ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
      end
    end

    test "the eager cap does not bound for_user" do
      4.times { |i| file("p#{i}.svg") }
      prior = ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"]
      # Far below the 4-file inbox -- if for_user read this variable at all, it would refuse the run.
      ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = "1"
      begin
        run = Maker::ProjectIntake.for_user(user: @user)
        assert_equal :ok, run.status
        assert_equal 4, run.results.sum { |_p, r| r.moved },
                     "for_user must not be bounded by PROJECT_ORGANIZE_EAGER_MAX_MOVES"
      ensure
        ENV["PROJECT_ORGANIZE_EAGER_MAX_MOVES"] = prior
      end
    end

    # A cycle in `nodes` must terminate rather than spin — fatal on SQLite, which has no statement
    # timeout. Reachable only via a crafted/corrupt tree, which is why it is a backstop and not a
    # feature.
    #
    # WHAT THIS TEST DOES NOT PROVE, RECORDED SO IT ISN'T RE-DISCOVERED THE HARD WAY: a 2-node cycle
    # is bounded fast by EITHER guard alone — MAX_DEPTH.times caps it at 32 quick iterations even
    # with no visited set, and the visited set alone catches the repeat at iteration 3 even with no
    # MAX_DEPTH. Verified by temporarily removing each guard in turn and re-running this test: both
    # variants still passed, in well under a second. Removing BOTH (a bare `loop do` with no set)
    # made it spin for real — the worker pegged at 100% CPU and had to be killed; it never returned.
    # So this test's genuine job is "terminates at all, however it does it" — not "MAX_DEPTH
    # specifically". The next test below is the one that isolates MAX_DEPTH.
    test "for_node terminates on a parent cycle" do
      a = dir("a")
      b = dir("b", parent: a.node_id)
      a.update!(parent_node_id: b.node_id)
      node = file("x.svg", parent: b.node_id)
      assert_nil Maker::ProjectIntake.for_node(user: @user, node:)
    end

    # THE DISCRIMINATING TEST the one above cannot be: a genuinely deep, NON-cyclic chain, longer
    # than MAX_DEPTH. The visited set never fires here — nothing repeats — so only the depth bound
    # can stop this walk short of `far_folder`. Mutation-verified: dropping `MAX_DEPTH.times` for a
    # bare `loop do` (keeping the visited set) makes this walk keep climbing past the bound, reach
    # far_folder, and resolve the project — this assertion flips from finding nil to finding a
    # Result, a genuine kill, not merely a slower pass.
    test "for_node does not resolve a project whose folder is more than MAX_DEPTH hops up" do
      far = @user.maker_projects.create!(name: "Far Away")
      far_folder = far.ensure_library_folder!(@user)
      deepest = (Maker::ProjectIntake::MAX_DEPTH + 4).times.inject(far_folder.node_id) do |parent, i|
        dir("level#{i}", parent:).node_id
      end
      node = file("buried.svg", parent: deepest)

      assert_nil Maker::ProjectIntake.for_node(user: @user, node:),
                 "far_folder is #{Maker::ProjectIntake::MAX_DEPTH + 4} hops up -- past MAX_DEPTH"
    end

    # for_node's THIRD return shape, distinct from both a Result and nil's usual two: a Result with
    # status: :no_folder when the resolved project's folder has been tombstoned. Inherited from
    # for_project/live_folder (see "a project whose folder was deleted is skipped..." above), but a
    # caller at THIS entry point that only checks `result.nil?` would read a dead folder as "nothing
    # to do" rather than a Result it still needs to inspect — which is exactly the mistake the
    # docstring now warns against.
    test "for_node answers a :no_folder Result, not nil, when the resolved project's folder was deleted" do
      node = file("panel.svg")
      @folder.update!(deleted: true)
      result = Maker::ProjectIntake.for_node(user: @user, node:)
      assert_not_nil result
      assert_equal :no_folder, result.status
      assert_equal 0, result.attached
    end
    # --- the repo shredder --------------------------------------------------------
    #
    # THE BUG THIS FIXES SHIPPED AND RAN UNATTENDED. §14f's root-is-inbox rule files every file at
    # a project folder's root by category, so a repo cloned at `Projects/<slug>/` lost README.md to
    # docs/, and main.py and platformio.ini to code/ (to other/, before the `code` role existed) on
    # every sweep — a delete plus an untracked add as far as git is concerned. Nested files were
    # always safe (already in a subfolder, never revisited); the root files are most of what
    # identifies a repo.
    test "a repo cloned at the project folder root is left entirely alone" do
      dir(".git")
      readme = file("README.md")
      main   = file("main.py")
      ini    = file("platformio.ini")

      result = intake

      assert_equal 0, result.moved, "the sweep must move nothing inside a working tree"
      [ readme, main, ini ].each do |node|
        assert_equal @folder.node_id, node.reload.parent_node_id,
                     "#{node.name} was moved out from under git"
      end
    end

    # THE CONTROL, so the test above cannot pass for the wrong reason. Remove the `.git` and the
    # identical fixtures must sort — otherwise "nothing moved" would be evidence of a broken sweep
    # rather than of the rule working.
    test "with NO .git, the same files sort normally" do
      readme = file("README.md")
      main   = file("main.py")

      result = intake

      assert_equal 2, result.moved
      assert_not_equal @folder.node_id, readme.reload.parent_node_id
      assert_not_equal @folder.node_id, main.reload.parent_node_id
    end

    # A repo one level down is the ordinary shape — `Projects/lamp/firmware/` is a checkout, and
    # the project root above it is still an inbox that must go on sorting.
    test "a repo in a SUBFOLDER does not freeze the project root's inbox" do
      repo = dir("firmware")
      dir(".git", parent: repo.node_id)
      loose = file("sketch.stl")

      result = intake

      assert_equal 1, result.moved
      assert_not_equal @folder.node_id, loose.reload.parent_node_id
    end

  # THE DESTINATION IS RESOLVED UNDER THE PROJECT'S FOLDER NODE, NEVER A PATH REBUILT FROM ITS SLUG.
  #
  # Reachable two ways, and Maker::ProjectDiscovery makes the second one the MAINLINE case:
  #   * rename a project's slug after its folder was minted — folder_node_id keeps pointing at the
  #     old `Projects/<old-slug>`;
  #   * adopt a folder whose NAME is not its slug — `Projects/Desk Lamp` with slug `desk-lamp`.
  #
  # Rebuilding the path mints a SECOND tree and moves the user's file into it, leaving the folder
  # the user made looking empty while the project still points at it. Nothing errors and nothing
  # logs — this repo's dominant failure shape.
  #
  # A SECOND PROJECT, not the fixture's @project, precisely because setup's
  # `ensure_library_folder!` gave that one a folder that DOES match its slug — which is the only
  # arrangement the old code could handle, and so the only one that could not catch this.
  test "a file is filed under the project's own folder node even when it is not named after the slug" do
    folder = dir("Desk Lamp", parent: nil)
    other  = @user.maker_projects.create!(name: "Bench Rig")
    other.update_column(:folder_node_id, folder.node_id)
    panel = file("panel.svg", parent: folder.node_id)

    Maker::ProjectIntake.for_project(user: @user, project: other)

    design = @user.nodes.present.find_by(parent_node_id: folder.node_id, name: "design",
                                         kind: "dir")
    refute_nil design, "the category folder must be created UNDER the project's own folder node"
    assert_equal design.node_id, panel.reload.parent_node_id
    assert_nil @user.nodes.present.find_by(name: "bench-rig", kind: "dir"),
               "no second Projects/<slug> tree may be minted"
  end
  end
end
