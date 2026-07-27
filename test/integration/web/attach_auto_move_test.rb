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
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = User.create!(email: "am-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @lamp = @user.maker_projects.create!(name: "Desk Lamp")
      @bench = @user.maker_projects.create!(name: "Bench")
      @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
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
      assert_empty @user.changelog_entries.where(op: "move"),
                   "nothing to move — the sync engine must not be told otherwise"
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
      dir = @user.nodes.create!(node_id: "d-1", name: "cad", kind: "dir")
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

    test "a JSON attach of a dir reports no relocation attempt at all" do
      @user.nodes.create!(node_id: "d-1", name: "cad", kind: "dir")
      post attachments_path, params: { project_id: @lamp.slug, node_id: "d-1" }, as: :json
      body = JSON.parse(response.body)
      # PRESENT-and-null, not merely absent: an absent key is also what dropping the field
      # altogether looks like, so asserting only assert_nil would pass for the bug.
      assert body.key?("relocation"), "the key must always be there"
      assert_nil body["relocation"],
                 "null is a third answer: 'not moved' and 'never tried' are different facts"
    end

    # --- what must NOT be swallowed ----------------------------------------------

    # THE NARROWING IS THE POINT. #relocate_into_project's rescue wraps the whole method, so a
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
      @user.nodes.create!(node_id: "f-3", name: "sub/dir.stl", kind: "file")

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

    # THE CONCERN'S CONTRACT IS "nil FOR EVERY can't-build CASE", and these are the two that are
    # not about ownership. Neither is hypothetical: the node one 500s the page it renders on
    # (@move_conflict.node.name on nil), and the folder one renders a prompt CLAIMING a collision
    # that never happened — a project with no folder has had no move attempted against it — while
    # computing its suggested name against the library ROOT.
    test "a prompt is not built for a deleted file, or for a project with no folder yet" do
      @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-gone", name: "old.stl", kind: "file", deleted: true)
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
        @user.nodes.create!(node_id: "f-taken-#{i}", name: "bracket (#{i}).stl", kind: "file",
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
      folder = @lamp.ensure_library_folder!(@user)
      @user.nodes.create!(node_id: "f-other", name: "bracket (2).stl", kind: "file",
                          parent_node_id: folder.node_id)

      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "bracket (2).stl" }

      assert_nil @node.reload.parent_node_id
      assert_match(/taken/i, flash[:alert])
    end

    test "relocate refuses a name that escapes the folder" do
      post relocate_project_attachments_path(@lamp),
           params: { node_id: "f-1", new_name: "../escape.stl" }

      @node.reload
      assert_nil @node.parent_node_id
      assert_equal "bracket.stl", @node.name
      assert_match(/couldn't move/i, flash[:alert])
    end

    # THE kind: "file" FILTER IS A GUARD. Both ids come from the request here, and Maker::MoveNode
    # deliberately has no cycle check — a crafted node_id naming a DIRECTORY would move a dir under
    # its own descendant on share and chunk, and a cycle in `nodes` makes Sync::Search's WITH
    # RECURSIVE walk spin unboundedly (fatal on SQLite, which has no statement timeout).
    test "relocate refuses a directory outright" do
      dir = @user.nodes.create!(node_id: "d-1", name: "cad", kind: "dir")

      post relocate_project_attachments_path(@lamp), params: { node_id: "d-1" }

      assert_nil dir.reload.parent_node_id
      assert_match(/isn't in your library/i, flash[:alert])
    end

    test "relocate never touches another user's file, or a tombstoned one" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: "of-1", name: "x.stl", kind: "file")
      mine_gone = @user.nodes.create!(node_id: "f-gone", name: "old.stl", kind: "file", deleted: true)

      post relocate_project_attachments_path(@lamp), params: { node_id: "of-1" }
      assert_nil theirs.reload.parent_node_id
      assert_match(/isn't in your library/i, flash[:alert])

      post relocate_project_attachments_path(@lamp), params: { node_id: "f-gone" }
      assert_nil mine_gone.reload.parent_node_id
      assert_match(/isn't in your library/i, flash[:alert])
    end

    # :already_there is reachable here and nowhere else in this flow: the prompt's button always
    # sends a new_name, but a resubmitted or hand-made POST without one, for a file that IS in the
    # folder, is a no-op — and "Couldn't move it" would be a lie about a library that is already
    # the way the user asked for.
    test "relocating a file that is already in place says so rather than claiming a move" do
      folder = @lamp.ensure_library_folder!(@user)
      @node.update!(parent_node_id: folder.node_id)

      post relocate_project_attachments_path(@lamp), params: { node_id: "f-1" }

      assert_match(/already in/i, flash[:notice])
      assert_equal folder.node_id, @node.reload.parent_node_id
      assert_empty @user.changelog_entries.where(op: "move"),
                   "nothing to move — the sync engine must not be told otherwise"
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
      @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id)
      folder
    end
  end
end
