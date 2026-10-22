require "test_helper"

module Web
  # Attaching a file to a project MOVES it into that project's library folder — unless it already
  # belongs to another project, in which case it stays where it is.
  #
  # PINNED TO CHUNK for every test that actually moves a file: the rule is backend-neutral, but the
  # move it drives is the two-door branch, and on share/s3 the port would need a real disk/bucket
  # behind every fixture. The doors themselves are covered per-backend in
  # test/services/maker/move_node_test.rb; what this file tests is the POLICY, one branch above.
  #
  # The exception is #with_broken_move, which swaps in a port-writable fake to make MoveNode take
  # the OTHER door and raise there. That is not a second backend under test — the fake holds no
  # bytes and the move never succeeds; it is the cheapest way to reach the failure branches, and
  # it deliberately drives the real MoveNode rather than stubbing it.
  class AttachAutoMoveTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A real share library, and fixtures that exist on disk -- see test_helper's create_node!
      # for why (§14a: a bare nodes.create! leaves a NULL storage_path, which cannot exist here).
      @root = use_fresh_share_library!
      @user = User.create!(email: "am-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @lamp = @user.maker_projects.create!(name: "Desk Lamp")
      @bench = @user.maker_projects.create!(name: "Bench")
      @node = create_node!(@user, node_id: "f-1", name: "bracket.stl", kind: "file")
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def lamp_folder
      @user.nodes.present.find_by!(name: @lamp.slug, kind: "dir")
    end

    # "The library backend is having a bad day", the house way (projects_flow_test.rb): swap
    # FileLayer.current for an object answering only what the code under test calls. Deliberately
    # NOT a stub of Maker::MoveNode — the point of these two tests is that the REAL move service
    # runs and the controller catches what it really raises. The caller pre-creates the project
    # folder, so ensure_library_folder! resolves from `nodes` and never reaches this fake's mkdir.
    def with_broken_move(error_class)
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      broken.define_singleton_method(:move) { |*| raise(error_class, "the backend is having a bad day") }
      FileLayer.current = broken
      yield
    ensure
      FileLayer.reset!
    end

    test "attaching an unattached file moves it into the project folder" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      @node.reload
      assert_equal lamp_folder.node_id, @node.parent_node_id
      assert_equal "f-1", @node.node_id, "the move must preserve node_id — the attachment points at it"
      assert_equal 1, @lamp.file_attachments.count
    end

    test "a file already attached to ANOTHER project is not moved" do
      @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      bench_folder = @bench.ensure_library_folder!(@user)
      @node.update!(parent_node_id: bench_folder.node_id)

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      assert_equal bench_folder.node_id, @node.reload.parent_node_id,
                   "a file claimed by another project stays put"
      assert_equal 1, @lamp.file_attachments.count, "…but the attach still happens"
    end

    test "a file already in the project folder is left alone (no redundant move)" do
      folder = @lamp.ensure_library_folder!(@user)
      @node.update!(parent_node_id: folder.node_id)

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      assert_equal folder.node_id, @node.reload.parent_node_id
    end

    test "the project page's nested picker moves too — one rule, every attach path" do
      post project_attachments_path(@lamp), params: { node_id: "f-1" }
      assert_equal lamp_folder.node_id, @node.reload.parent_node_id
    end

    test "attaching from the file page returns to the file page, not the project" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      assert_redirected_to file_path("f-1")
    end

    test "attaching without return_to still lands on the project, as it always has" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      assert_redirected_to project_path(@lamp)
    end

    # return_to is a FLAG, not a destination. The controller comment claims a caller-supplied
    # target can't become an open redirect; this is what makes that claim checkable.
    test "an arbitrary return_to is ignored, not followed" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1",
                                       return_to: "https://evil.example.com/steal" }
      assert_redirected_to project_path(@lamp)
    end

    test "a directory is never moved" do
      dir = create_node!(@user, node_id: "d-1", name: "cad", kind: "dir")
      post attachments_path, params: { project_id: @lamp.slug, node_id: "d-1" }
      assert_nil dir.reload.parent_node_id, "dirs are not relocated (s3 refuses them outright)"
    end

    test "an unreachable library leaves the attachment in place and says so" do
      @lamp.ensure_library_folder!(@user) # the folder predates the outage

      with_broken_move(FileLayer::FetchError) do
        post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      end

      assert_equal 1, @lamp.file_attachments.count,
                   "an attach is bookkeeping — it must never fail because the NAS is unplugged"
      assert_nil @node.reload.parent_node_id, "and nothing moved"
      assert_match(/couldn't move/i, flash[:notice])
    end

    # NotFound is REACHABLE here and it is NOT a caller error: #create has already proved the node
    # is live and this user's, and ensure_library_folder! has just proved the destination exists —
    # so a NotFound from the move is a race (the node tombstoned between the two statements) or an
    # out-of-band change under a share/s3 store. Letting it escape would 500 the request AFTER the
    # attachment row is committed: the reference the user asked for exists, and we tell them the
    # whole thing failed. It belongs in the best-effort bucket with FetchError.
    test "a node that vanishes mid-attach keeps the attachment and does not 500" do
      @lamp.ensure_library_folder!(@user)

      with_broken_move(FileLayer::NotFound) do
        post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      end

      assert_response :redirect
      assert_equal 1, @lamp.file_attachments.count
      assert_match(/couldn't move/i, flash[:notice])
    end

    # A collision must not be swallowed and must not lose the attach: it rides back as
    # ?move_conflict=<attachment id>, which the MoveConflicts concern renders the prompt from (the
    # prompt's own tests are further down).
    test "a name collision in the project folder attaches anyway and flags the conflict" do
      seed_collision

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      att = @lamp.file_attachments.sole
      assert_nil @node.reload.parent_node_id, "the colliding move must not happen"
      assert_redirected_to project_path(@lamp, move_conflict: att.id)
    end

    # The prompt is not a substitute for the flash: it renders in the page body, and a user who
    # reads the flash and moves on would otherwise never learn the move did not happen.
    test "a collision says so in the flash, not just in the query string" do
      seed_collision
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      assert_match(/already has a file with that name/i, flash[:notice])
      assert_match(/stayed put/i, flash[:notice])
    end

    # --- the JSON door must tell the same truth as the HTML one -------------------

    test "the JSON attach reports the relocation, not just the row" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }, as: :json
      assert_response :created
      assert_equal "moved", JSON.parse(response.body)["relocation"]
    end

    # The bug this pins: a colliding JSON attach used to answer a bare 201 and uploader_controller
    # reported "Done." for a file that never moved. The status can't carry it — the attach really
    # did succeed — so it has to be in the body.
    test "a colliding JSON attach is still 201 but says the move did not happen" do
      seed_collision
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }, as: :json
      assert_response :created
      assert_equal "conflict", JSON.parse(response.body)["relocation"]
      assert_nil @node.reload.parent_node_id
    end

    # A dir CAN belong to a model (Models::AttachmentsController does not filter by kind), and the
    # bundle path keeps live FILES only — so the triggering node was missing from its own result
    # and this door raised `undefined method 'node_id' for nil`. Reproduced before the fix; the
    # HTML door's version of it said "Attached 0 files from Widget."
    test "a JSON attach of a dir that belongs to a model answers instead of 500-ing" do
      dir = create_node!(@user, node_id: "d-1", name: "cad", kind: "dir")
      model = @user.maker_models.create!(title: "Widget")
      model.file_attachments.create!(user: @user, node_id: "d-1", role: "other")

      post attachments_path, params: { project_id: @lamp.slug, node_id: "d-1" }, as: :json

      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "d-1", body["node_id"]
      assert_nil body["relocation"]
      assert_nil dir.reload.parent_node_id
    end

    test "a JSON attach of a dir reports no relocation attempt at all" do
      create_node!(@user, node_id: "d-1", name: "cad", kind: "dir")
      post attachments_path, params: { project_id: @lamp.slug, node_id: "d-1" }, as: :json
      body = JSON.parse(response.body)
      # PRESENT-and-null, not merely absent: an absent key is also what dropping the field
      # altogether looks like, so asserting only assert_nil would pass for the bug.
      assert body.key?("relocation"), "the key must always be there"
      assert_nil body["relocation"],
                 "null is a third answer: 'not moved' and 'never tried' are different facts"
    end

    # --- what must NOT be swallowed ----------------------------------------------

    # THE NARROWING IS THE POINT. Maker::AttachToProject#move's rescue wraps the whole method, so a
    # too-wide list turns bugs into "the library is having a bad day" with a green suite. A bare
    # ArgumentError — arity drift in a port adapter's #move, a kwarg rename, a nil reaching
    # File.extname — must reach the error handler, not the flash.
    test "an ArgumentError that is not InvalidName is NOT swallowed as an outage" do
      @lamp.ensure_library_folder!(@user)

      assert_raises(ArgumentError) do
        with_broken_move(ArgumentError) do
          post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
        end
      end
    end

    # …while the one ArgumentError this flow really can produce still degrades gracefully. Reached
    # for real, not by a fake: Node validates name PRESENCE only, so a row whose name carries a
    # separator is storable and MoveNode#leaf! rejects it.
    test "a node whose own name is not a leaf degrades instead of 500-ing" do
      create_node!(@user, node_id: "f-3", name: "sub/dir.stl", kind: "file")

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-3" }

      assert_response :redirect
      assert_equal 1, @lamp.file_attachments.count
      assert_match(/couldn't move/i, flash[:notice])
    end

    # --- the file page's node vanished under it ----------------------------------

    test "a not-found attach from the file page does not dump the user in a project picker" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "gone", return_to: "file" }
      # files_path, NOT file_path("gone"): FilesController#show would 404 on the very condition
      # that got us here, and take the alert down with it.
      assert_redirected_to files_path
      assert_match(/isn't in your library/i, flash[:alert])
    end

    test "a not-found attach from the project picker still returns to the picker" do
      post attachments_path, params: { project_id: @lamp.slug, node_id: "gone" }
      assert_redirected_to new_project_attachment_path(@lamp)
    end

    # --- the collision prompt (?move_conflict=<attachment id>) ---------------------
    #
    # The redirect param above is only half the flow: something has to RENDER it, on both pages an
    # attach can come from. These tests are the other half.

    test "a name collision attaches anyway and prompts instead of clobbering" do
      seed_collision

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }

      att = @lamp.file_attachments.sole
      assert_redirected_to file_path("f-1", move_conflict: att.id)
      assert_nil @node.reload.parent_node_id, "the file must not have moved…"
      assert_equal "bracket.stl", @user.nodes.find_by(node_id: "f-2").name,
                   "…and the file already there must be untouched"
    end

    test "the prompt offers the suggested name and a way out" do
      seed_collision
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      follow_redirect!

      assert_select "dialog.move-conflict"
      assert_select "dialog.move-conflict", text: /bracket \(2\)\.stl/
      assert_select "dialog.move-conflict a", text: /Leave it where it is/
    end

    # THE DISMISSAL IS THE URL WITHOUT THE PARAM, and it has to be built from request.path rather
    # than url_for(params:) — a trap this codebase has been bitten by before (a stray param rides
    # along and the "dismissal" re-renders the prompt). An href assertion is the only thing that
    # can tell the two implementations apart.
    test "the way out drops the query string entirely" do
      seed_collision
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      follow_redirect!

      assert_select "dialog.move-conflict a[href=?]", file_path("f-1"), text: /Leave it where it is/
    end

    test "the prompt also renders on the project page" do
      seed_collision
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
      follow_redirect!

      assert_select "dialog.move-conflict"
    end

    test "no prompt without the param, and a bogus id is silently ignored" do
      get file_path("f-1")
      assert_select "dialog.move-conflict", count: 0
      get file_path("f-1", move_conflict: 999_999)
      assert_select "dialog.move-conflict", count: 0
    end

    # THE FOREIGN ROW POINTS AT MY node_id ON PURPOSE, and the whole guard hangs on that. node_id
    # is a bare string in maker_file_attachments with no FK (model_owning's comment says the same
    # thing about the same table), so another tenant's row naming "f-1" is perfectly storable —
    # and an unscoped lookup here would render THEIR project's name and a link to it on MY page.
    # A foreign row pointing at a foreign node proves nothing: the node lookup below catches that
    # one, so the test would stay green with the attachment scope removed. Verified by mutation.
    test "another user's attachment id never renders a prompt" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")
      theirs.ensure_library_folder!(other)
      foreign = theirs.file_attachments.create!(user: other, node_id: "f-1", role: "model")

      get file_path("f-1", move_conflict: foreign.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0
      assert_no_match(/Theirs/, response.body)
    end

    # attachable_type IS A GUARD, not a redundant filter next to the id lookup. The same table
    # holds a file's attachments to Maker::Models and to build-log entries, and the partial reads
    # its `project` as one — `.name`, project_path, the project-scoped relocate route. Deleting the
    # filter 500s this page on `undefined method 'name' for an instance of Maker::Model` (a model
    # has a `title`), which is the cheap end of the same mistake: a Maker::BuildLogEntry has
    # neither, and any attachable that happened to answer both would render a prompt offering to
    # move the file somewhere it has nothing to do with.
    #
    # THE MODEL NEEDS ITS FOLDER for this test to mean anything: maker_models has a folder_node_id
    # column of its own, so an unfoldered model trips the folder guard and the test passes with the
    # type filter deleted. Verified by mutation.
    test "a model attachment's id never renders a project prompt" do
      model = @user.maker_models.create!(title: "Widget")
      model.ensure_library_folder!(@user)
      att = model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      get file_path("f-1", move_conflict: att.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0
    end

    # THE PROMPT MUST RE-ESTABLISH ITS OWN SENTENCE, not a proxy for it. The premise is "a file
    # with that name is already in the project's folder"; an earlier version asked "is the node in
    # the folder?", which is a different question and rendered a prompt in all three of these — the
    # first reachable with NO URL editing at all, from any attachment the inline-upload or tool-save
    # paths made. The suggestion was wrong too: it offered "bracket (2).stl" while "bracket.stl"
    # was free.
    test "no collision, no prompt — an empty folder or a sibling deleted out of band" do
      folder = @lamp.ensure_library_folder!(@user)
      empty_folder_attachment = attach!

      get file_path("f-1", move_conflict: empty_folder_attachment.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0, message: "nothing in the folder to collide with"

      sibling = create_node!(@user, node_id: "f-2", name: "bracket.stl", kind: "file",
                                    parent_node_id: folder.node_id)
      get file_path("f-1", move_conflict: empty_folder_attachment.id)
      assert_select "dialog.move-conflict", 1, "precondition: a real collision does render"

      sibling.update!(deleted: true)
      get file_path("f-1", move_conflict: empty_folder_attachment.id)
      assert_select "dialog.move-conflict", count: 0, message: "the collision is gone"
    end

    # DON'T OFFER A BUTTON THE SERVICE WILL REFUSE. The app never mints ?move_conflict= for a
    # bundle member or a file another project claims — but attachment ids are sequential integers
    # and the URL is on screen right after any collision, so typing one used to yield a dialog
    # whose every word was false, wired to a move that gutted a model's folder.
    test "no prompt for a file the policy will not move" do
      model = @user.maker_models.create!(title: "Widget")
      model.ensure_library_folder!(@user)
      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      seed_collision
      bundle_member = attach!

      get file_path("f-1", move_conflict: bundle_member.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0, message: "a model's files stay together"
    end

    test "no prompt for a file another project already claims" do
      seed_collision
      claimed = attach!
      attach!(@bench)

      get file_path("f-1", move_conflict: claimed.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0
    end

    # THE PARAM OUTLIVES THE CONFLICT. #relocate lands back on the page the button was on, and
    # browsers have a Back key — so the id survives the move it asked for. The prompt would then
    # state something now false ("it was left where it is") while offering "bracket (2) (2).stl".
    test "the prompt stops rendering once the move it offered has happened" do
      seed_collision
      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      att = @lamp.file_attachments.sole
      follow_redirect!
      assert_select "dialog.move-conflict", 1, "precondition: the prompt is showing"

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" }

      get file_path("f-1", move_conflict: att.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0
    end

    # THE CONCERN'S CONTRACT IS "nil FOR EVERY can't-build CASE", and these are the two that are
    # not about ownership. Neither is hypothetical: the node one 500s the page it renders on
    # (@move_conflict.node.name on nil), and the folder one renders a prompt CLAIMING a collision
    # that never happened — a project with no folder has had no move attempted against it — while
    # computing its suggested name against the library ROOT.
    test "a prompt is not built for a deleted file, or for a project with no folder yet" do
      @lamp.ensure_library_folder!(@user)
      create_node!(@user, node_id: "f-gone", name: "old.stl", kind: "file", deleted: true)
      for_a_tombstone = @lamp.file_attachments.create!(user: @user, node_id: "f-gone", role: "model")

      get file_path("f-1", move_conflict: for_a_tombstone.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0

      # @bench is untouched by the setup, so it has never had a library folder ensured.
      folderless = @bench.file_attachments.create!(user: @user, node_id: "f-1", role: "model")
      assert_nil @bench.reload.folder_node_id

      get file_path("f-1", move_conflict: folderless.id)
      assert_response :success
      assert_select "dialog.move-conflict", count: 0
    end

    # available_name answers nil when "(2)" through "(9)" are all taken. The prompt still has
    # something to say — the file was attached and did not move — so it renders WITHOUT the button
    # rather than not at all, and certainly rather than offering a nil name.
    test "with every suggestion taken the prompt still explains itself, minus the button" do
      folder = seed_collision
      (2..Maker::MoveNode::HIGHEST_SUFFIX).each do |i|
        create_node!(@user, node_id: "f-taken-#{i}", name: "bracket (#{i}).stl", kind: "file",
                            parent_node_id: folder.node_id)
      end

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1", return_to: "file" }
      follow_redirect!

      assert_select "dialog.move-conflict"
      assert_select "dialog.move-conflict form", count: 0, message: "no name left to offer"
      assert_select "dialog.move-conflict a", text: /Leave it where it is/
    end

    # --- #relocate: finish the move the collision stopped -------------------------

    test "relocate moves the file under the suggested name" do
      folder = seed_collision
      attach!

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" }

      @node.reload
      assert_equal folder.node_id, @node.parent_node_id
      assert_equal "bracket (2).stl", @node.name
      assert_equal "f-1", @node.node_id
      # THE NOTICE NAMES THE NEW NAME, which is the only thing telling the user what to look for —
      # the file they clicked "bracket.stl" on is now called something else. It reads off the
      # object MoveNode hands back, so it is a consumer of that class's reload contract (pinned
      # per-backend in test/services/maker/move_node_test.rb; this leg is chunk).
      assert_match(/Moved bracket \(2\)\.stl into Desk Lamp/, flash[:notice])
    end

    test "relocate onto a name that is ALSO taken says so instead of clobbering" do
      attach!
      folder = @lamp.ensure_library_folder!(@user)
      create_node!(@user, node_id: "f-other", name: "bracket (2).stl", kind: "file",
                          parent_node_id: folder.node_id)

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" }

      assert_nil @node.reload.parent_node_id
      assert_match(/taken/i, flash[:alert])
    end

    test "relocate refuses a name that escapes the folder" do
      attach!

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "../escape.stl" }

      @node.reload
      assert_nil @node.parent_node_id
      assert_equal "bracket.stl", @node.name
      # ITS OWN SENTENCE, not the :unavailable one. "Couldn't move it right now" means try again
      # later, and a name that is not a leaf never succeeds on retry — move_node.rb asked for the
      # split by name, and this endpoint is the caller it anticipated.
      assert_match(/name isn't allowed/i, flash[:alert])
    end

    # THE kind: "file" FILTER IS A GUARD. Both ids come from the request here, and Maker::MoveNode
    # deliberately has no cycle check — a crafted node_id naming a DIRECTORY would move a dir under
    # its own descendant on share and chunk, and a cycle in `nodes` makes Sync::Search's WITH
    # RECURSIVE walk spin unboundedly (fatal on SQLite, which has no statement timeout).
    test "relocate refuses a directory outright" do
      dir = create_node!(@user, node_id: "d-1", name: "cad", kind: "dir")

      post relocate_project_attachments_path(@lamp), params: { node_id: "d-1" }

      assert_nil dir.reload.parent_node_id
      assert_match(/isn't in your library/i, flash[:alert])
    end

    test "relocate never touches another user's file, or a tombstoned one" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = create_node!(other, node_id: "of-1", name: "x.stl", kind: "file")
      mine_gone = create_node!(@user, node_id: "f-gone", name: "old.stl", kind: "file", deleted: true)

      post relocate_project_attachments_path(@lamp), params: { node_id: "of-1" }
      assert_nil theirs.reload.parent_node_id
      assert_match(/isn't in your library/i, flash[:alert])

      post relocate_project_attachments_path(@lamp), params: { node_id: "f-gone" }
      assert_nil mine_gone.reload.parent_node_id
      assert_match(/isn't in your library/i, flash[:alert])
    end

    # A RESUBMIT OF THE PROMPT'S OWN BUTTON, which is the ordinary way to reach :already_there: the
    # first POST applied "bracket (2).stl", so the second asks to move the file to where it already
    # is. The changelog assertion is the point — a move to the same parent under the same name is a
    # no-op, and broadcasting it tells every device to apply nothing. The suite already pins that
    # for #create ("no redundant move"); the new endpoint must not be the one that breaks it.
    test "resubmitting the prompt's button is a no-op, not a second move" do
      seed_collision
      attach!

      2.times do
        post relocate_project_attachments_path(@lamp),
             params: { node_id: "f-1", new_name: "bracket (2).stl" }
      end

      assert_equal "bracket (2).stl", @node.reload.name
      # FIRST, so a regression's failure message names the sync consequence rather than the wording.
      assert_match(/already in/i, flash[:notice])
    end

    # The same short-circuit reached the other way: no new_name at all, for a file already in the
    # folder. "Couldn't move it" would be a lie about a library that is already the way the user
    # asked for.
    test "relocating a file that is already in place says so rather than claiming a move" do
      attach!
      folder = @lamp.ensure_library_folder!(@user)
      @node.update!(parent_node_id: folder.node_id)

      post relocate_project_attachments_path(@lamp), params: { node_id: "f-1" }

      assert_match(/already in/i, flash[:notice])
      assert_equal folder.node_id, @node.reload.parent_node_id
    end

    # --- #relocate obeys the SAME policy #create does -----------------------------
    #
    # THE BUG THESE EXIST FOR: the rules used to live inline in #create, and #relocate called the
    # move directly, below all of them. Three did not come along. They are one object now
    # (Maker::AttachToProject), unit-tested per rule in test/services/maker/attach_to_project_test.rb;
    # these drive the same rules through the endpoint a browser can reach.

    # THE CRITICAL ONE. #create refuses to pull one file out of a model's bundle — "would pull ONE
    # of those out and report success, gutting the model's folder". #relocate did exactly that,
    # reproduced against a three-file model: the folder was left holding two files and the flash
    # said "Moved widget.stl into Desk Lamp."
    test "relocate never pulls a file out of its model's bundle" do
      model = @user.maker_models.create!(title: "Widget")
      folder = model.ensure_library_folder!(@user)
      %w[widget.stl instructions.pdf cover.png].each_with_index do |name, i|
        create_node!(@user, node_id: "m-#{i}", name:, kind: "file", parent_node_id: folder.node_id)
        model.file_attachments.create!(user: @user, node_id: "m-#{i}", role: "other")
      end
      # The attach itself is allowed and brings the whole bundle (Task 3b) — so the attachment
      # #relocate requires EXISTS, and only the bundle rule stands between it and the folder.
      post attachments_path, params: { project_id: @lamp.slug, node_id: "m-0" }

      post relocate_project_attachments_path(@lamp), params: { node_id: "m-0" }

      assert_equal folder.node_id, @user.nodes.find_by(node_id: "m-0").parent_node_id
      assert_equal %w[widget.stl instructions.pdf cover.png].sort,
                   @user.nodes.present.where(parent_node_id: folder.node_id).pluck(:name).sort,
                   "the model's folder must still hold every one of its files"
      assert_match(/part of Widget/, flash[:alert])
    end

    test "relocate does not yank a file out of another project's folder" do
      bench_folder = @bench.ensure_library_folder!(@user)
      @node.update!(parent_node_id: bench_folder.node_id)
      attach!(@bench)
      attach!(@lamp)

      post relocate_project_attachments_path(@lamp), params: { node_id: "f-1" }

      assert_equal bench_folder.node_id, @node.reload.parent_node_id
      assert_match(/belongs to another project/i, flash[:alert])
    end

    # AN ACTION ON THE ATTACHMENTS CONTROLLER MUST TOUCH AN ATTACHMENT. Without this rule, POSTing
    # a node_id to a project the user never attached anything to moved the file in AND minted
    # Projects/<slug> as a side effect. "Attached ⇒ in the folder" is the rule the move enforces; a
    # file that has not joined the project has nothing to finish.
    test "relocate refuses when the file is not attached to this project, and mints no folder" do
      post relocate_project_attachments_path(@bench), params: { node_id: "f-1" }

      assert_nil @node.reload.parent_node_id
      assert_nil @bench.reload.folder_node_id, "the endpoint must not create a folder to refuse into"
      assert_equal 0, @bench.file_attachments.count
      assert_match(/isn't attached to Bench/i, flash[:alert])
    end

    # --- what a request-shaped `new_name` must not become -------------------------

    # A NON-STRING BYPASSED leaf! ON CHUNK, THE MAIN DEPLOYMENT. `["a/b.stl"].include?("/")` asks
    # whether an ELEMENT equals "/", so every shape check passed and the chunk door committed a
    # node literally named `["a/b.stl"]` — a separator inside `nodes.name`, broadcast to every
    # device. FileLayer::Share#leaf! escaped only by calling .to_s first, so share and s3 were safe.
    test "an array-shaped new_name is refused, not stringified into a name" do
      attach!

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: [ "a/b.stl" ] }

      @node.reload
      assert_equal "bracket.stl", @node.name
      assert_nil @node.parent_node_id
      assert_match(/name isn't allowed/i, flash[:alert])
    end

    # THE WRITE COMMITTED BEFORE THE 500. A ~4 KB name renamed the file and appended the changelog
    # entry, then blew the session cookie — the user's file permanently renamed to 4000 characters,
    # on every device, and an error page to look at. No client filesystem can create it (255 bytes
    # on ext4/APFS/NTFS), so it syncs and then cannot be written down.
    test "an absurdly long new_name is refused before anything is written" do
      attach!

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "#{'x' * 4000}.stl" }

      assert_response :redirect
      assert_equal "bracket.stl", @node.reload.name
    end

    # Harmless on POSIX; on a Windows CfAPI client — the DEFAULT Windows backend — a backslash is a
    # separator, so this is the same "a path that exists in no tree" bug wearing another OS.
    test "a backslash in new_name is refused like a slash" do
      attach!

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: 'sub\\evil.stl' }

      assert_equal "bracket.stl", @node.reload.name
      assert_match(/name isn't allowed/i, flash[:alert])
    end

    # BOTH raised an uncaught `TypeError: can't cast ActionController::Parameters` — a 500 from a
    # garbage param, and #relocate's own comment promised "never a 500". The node_id half is
    # #create's too, and predates this endpoint.
    test "hash-shaped params answer honestly instead of 500-ing" do
      attach!

      post relocate_project_attachments_path(@lamp), params: { node_id: "f-1", new_name: { a: "b" } }
      assert_response :redirect
      assert_equal "bracket.stl", @node.reload.name

      post relocate_project_attachments_path(@lamp), params: { node_id: { a: "b" } }
      assert_response :redirect
      assert_match(/isn't in your library/i, flash[:alert])

      post attachments_path, params: { project_id: @lamp.slug, node_id: { a: "b" } }
      assert_response :redirect
      assert_match(/isn't in your library/i, flash[:alert])
    end

    # The button is on two pages, so it has to come back to whichever one it was pressed on.
    # `redirect_back_or_to` reads the Referer (same-host only — allow_other_host resolves to false
    # under this app's config), which is why #relocate needs none of #create's return_to plumbing.
    test "relocate returns to the page the button was on" do
      seed_collision
      attach!

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" },
           headers: { "HTTP_REFERER" => file_path("f-1") }

      assert_redirected_to file_path("f-1")
    end

    # :unavailable persists no marker anywhere, so after a NAS outage this one line is the only
    # way to answer "which files failed to move?". That makes the node_id part of the behavior,
    # not of the phrasing.
    test "the failure log names the file and the project" do
      @lamp.ensure_library_folder!(@user)

      logged = capture_rails_log do
        with_broken_move(FileLayer::FetchError) do
          post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }
        end
      end

      assert_match(/node=f-1/, logged)
      assert_match(/project=desk-lamp/, logged)
    end

    private

    # Minitest parallelises with PROCESSES here, so swapping the global logger cannot bleed into a
    # concurrently running test.
    def capture_rails_log
      sink = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(sink)
      yield
      sink.string
    ensure
      Rails.logger = original
    end

    # A live sibling already holding "bracket.stl" in the project folder.
    def seed_collision
      folder = @lamp.ensure_library_folder!(@user)
      create_node!(@user, node_id: "f-2", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id)
      folder
    end

    # The attachment #relocate requires. The real flow gets it from #create (which is what the
    # tests above drive); a test that starts at #relocate has to stand it up, because the endpoint
    # finishes an attach and refuses when there is none to finish.
    def attach!(project = @lamp, node_id = "f-1")
      project.file_attachments.create!(user: @user, node_id:, role: "model")
    end
  end
end
