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
    # ?move_conflict=<attachment id>, which Task 4's prompt renders from.
    test "a name collision in the project folder attaches anyway and flags the conflict" do
      seed_collision

      post attachments_path, params: { project_id: @lamp.slug, node_id: "f-1" }

      att = @lamp.file_attachments.sole
      assert_nil @node.reload.parent_node_id, "the colliding move must not happen"
      assert_redirected_to project_path(@lamp, move_conflict: att.id)
    end

    # ?move_conflict= is read by nothing until the rename prompt lands, so the notice is the only
    # thing standing between the user and a silent no-op.
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
