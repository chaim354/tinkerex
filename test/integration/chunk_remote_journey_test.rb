# frozen_string_literal: true

require "test_helper"
require_relative "../support/chunk_remote_journey"

# DRIVES THE MAKER APP AGAINST A REAL STANDALONE SYNC SERVER. Every node here is created through a
# real door -- never `user.nodes.create!` -- because a hand-built row exists only in the local
# mirror and the server has never heard of it, so a write verb against one would 404 for a reason
# that says nothing about chunk_remote.
#
# THIS SUITE IS ARC A'S INSTRUMENT, NOT ARC A'S PRODUCT -- but be precise about which tests that
# covers. An earlier version of this comment claimed the whole class was "expected to be red when
# it lands," and that was already wrong once: these three tests came back GREEN on the FIRST run
# against a real standalone server, not asserted on faith -- verified against that server's own
# log as genuine wire traffic (a presigned chunk PUT, `finalize` inserting a real
# `Version`/`Node`/`ChangelogEntry` row apiece, and the `/v1/changes` pull that refreshes the local
# mirror's `nodes` table). The failures Arc B works from are the three tests Task 5 adds -- each
# names its own expected failure individually, rather than this docstring claiming one on the
# whole file's behalf. It is deliberately NOT a bin/ci gate -- test/ci_hygiene_test.rb asserts set
# equality between `bin/ci --list-ci` and ci.yml's gate jobs, so a red gate is a red main.
# .github/workflows/sync-contract.yml carries the signal.
class ChunkRemoteJourneyTest < ActionDispatch::IntegrationTest
  include ChunkRemoteJourney

  # NO SHARED `setup` HERE, DELIBERATELY -- see the canary test immediately below for the reason.
  # Every other test in this class calls `skip_unless_remote_server` itself, as its own first line.

  # THE MUTATION-CHECK ON THE SKIP ITSELF, KEPT OUT OF `setup` AND OUT OF THE HELPER ON PURPOSE.
  # §14j records a guard that skipped on `defined?(Sync)` -- the very thing it asserted -- so the
  # mutation that broke it made every test skip and the suite report success. An earlier version of
  # THIS test shared `setup { skip_unless_remote_server }` with every other test in the class, which
  # rebuilt that exact failure one level up: `setup` runs before this test's own body too, so
  # breaking `skip_unless_remote_server` to always skip took this canary down WITH the other eight
  # -- the suite reported nine skips, zero failures, success, having asserted nothing. A guard that
  # shares a mechanism with the thing it checks inherits that thing's failures.
  #
  # So this test does not call `skip_unless_remote_server` at all -- it duplicates that method's
  # CONDITION inline instead. Do not "simplify" this back into `setup` or a call to the helper; that
  # reintroduces the exact blind spot above. (`ChunkRemoteJourney.configured?` is still shared, but
  # it is a pure predicate with no skip of its own -- the thing that must not be shared is the
  # SKIPPING, i.e. `skip_unless_remote_server` itself, and this test performs its own, independent
  # skip rather than delegating to that method.)
  #
  # Two of the three assertions this test used to make were tautological once `setup` had already
  # skipped for anything but a configured, chunk_remote-backend run -- by the time the body ran,
  # `configured?` and `LIBRARY_BACKEND == "chunk_remote"` were already-established facts, not open
  # questions. Only `FileLayer.current`'s class carries independent content, so that is the one
  # assertion kept.
  test "the journey suite does not skip when a server is configured" do
    skip "no server configured for this run" unless ChunkRemoteJourney.configured? &&
      ENV["LIBRARY_BACKEND"] == "chunk_remote"

    assert_kind_of FileLayer::ChunkRemote, FileLayer.current
  end

  test "an upload round-trips byte-for-byte through the sync server" do
    skip_unless_remote_server
    sign_in
    # CONTENT varies, not just the filename. Chunks are content-addressed, so a repeat of fixed
    # bytes dedupes to an empty put_urls and the Net::HTTP upload path silently never runs --
    # see upload_through_ui's own comment. The suite would stay green while proving nothing.
    bytes = "solid #{journey_prefix}\nendsolid\n".b
    node_id = upload_through_ui("#{journey_prefix}-bracket.stl", bytes)

    get blob_file_path(node_id)
    assert_response :success
    assert_equal bytes, response.body,
                 "the bytes that came back are not the bytes that went in"
  end

  # A DEDICATED FOLDER, NOT THE LIBRARY ROOT. This suite is explicitly designed to be re-run
  # against one long-lived sync server that never rolls back (see journey_prefix's own comment), so
  # every prior run's uploads accumulate at the root forever. `FilesController::FOLDER_PAGE` is 250
  # (files_controller.rb:741) and the index defaults to name-ascending, so once accumulated runs
  # push root children past 250, a randomly-named file no longer lands on the first page and
  # `assert_includes` starts failing -- with nothing wrong in the app. A folder scopes
  # `FilesController#index`'s query (`where(parent_node_id: @folder&.node_id)`,
  # files_controller.rb:192), so a per-run folder holding exactly one file can never be pushed past
  # the first page, however many runs came before it. `params[:folder]` is a parent node_id
  # (files_controller.rb:141).
  test "an uploaded file appears on the files page" do
    skip_unless_remote_server
    user = sign_in
    folder = "#{journey_prefix}-listing"
    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success, "create_folder failed: #{response.body}"
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    name = "#{journey_prefix}-listed.stl"
    upload_through_ui(name, "listed #{journey_prefix}".b, parent_node_id: folder_node.node_id)

    get files_path(folder: folder_node.node_id)
    assert_response :success
    assert_includes response.body, name

    assert user.nodes.present.exists?(name:),
           "the local mirror should hold the node after finalize_upload refreshed it"
  end

  test "a folder can be created, and a file moved into it" do
    skip_unless_remote_server
    user = sign_in
    folder = "#{journey_prefix}-folder"
    node_id = upload_through_ui("#{journey_prefix}-moved.stl", "moved #{journey_prefix}".b)

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success, "create_folder failed: #{response.body}"
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    # THROUGH Maker::MoveNode, NOT a controller: verified against `bin/rails routes` -- FilesController
    # exposes GET/DELETE on /files/:id and no update action at all, so there is no PATCH door to
    # drive. MoveNode is the named service §14d says every web move goes through, which makes it the
    # real door here rather than a shortcut past one.
    Maker::MoveNode.call(user, node: user.nodes.present.find_by!(node_id:),
                         new_parent_node_id: folder_node.node_id)

    assert_equal folder_node.node_id, user.nodes.present.find_by!(node_id:).parent_node_id,
                 "the move did not reach the mirror -- refresh! after move is what puts it there"
  end

  test "a file can be deleted, listed in trash, and restored" do
    skip_unless_remote_server
    user = sign_in
    name = "#{journey_prefix}-doomed.stl"
    node_id = upload_through_ui(name, "doomed #{journey_prefix}".b)

    # `assert_response :redirect` WOULD NOT DISCRIMINATE HERE, and that is the same defect the
    # journey harness's own sign_in had. FilesController redirects to files_path on SUCCESS
    # (files_controller.rb:628, with a notice) and its three rescue_from arms redirect to
    # files_path on EVERY html failure (:106 NotFound, :124 FetchError, :134
    # UnsupportedOperation), each with an ALERT. Same status, same Location -- the flash is the
    # only thing that differs, so it is what gets asserted.
    delete file_path(node_id)
    assert_redirected_to files_path
    assert_nil flash[:alert], "delete was refused: #{flash[:alert]}"
    assert_not user.nodes.present.exists?(node_id:), "delete did not tombstone the mirror row"

    get trash_index_path
    assert_response :success
    assert_includes response.body, name

    post restore_trash_path(node_id)
    # TrashController's failure arms redirect to trash_index_path with an alert (:40, :46) while
    # success goes to files_path with a notice (:79), so the destination alone would discriminate
    # here -- the alert check is kept anyway so every redirect in this file reads the same way.
    assert_redirected_to files_path
    assert_nil flash[:alert], "restore was refused: #{flash[:alert]}"
    assert user.nodes.present.exists?(node_id:), "restore did not revive the mirror row"
  end

  # DEEPENED PAST ONE LEVEL, DELIBERATELY. The original fixture was folder -> file, which a
  # server-side SubtreeDelete could satisfy with a single `WHERE parent_node_id = ?` and no
  # recursion -- passing this exact test while still orphaning folder/subfolder/file.stl. §14a's
  # trap is about EVERY descendant, not merely direct children, so the fixture now nests a
  # subfolder under the folder and a grandchild under that, and the delete is issued against the
  # TOP folder only. The one-level half of this test is kept and already verified empirically: an
  # orphaning delete genuinely fails here, because `Node.present` filters on the row's own
  # `deleted` column, not on its ancestor chain, so an untombstoned child stays visible even with a
  # tombstoned parent -- this fixture cannot pass by accident.
  test "a directory delete cascades, because dir_deletable is true on chunk_remote" do
    skip_unless_remote_server
    user = sign_in
    folder = "#{journey_prefix}-cascade"

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    child = upload_through_ui("#{journey_prefix}-child.stl", "child #{journey_prefix}".b,
                              parent_node_id: folder_node.node_id)
    # THE MISSING PRECONDITION. Without this, a future regression in begin_upload's
    # parent_node_id plumbing fails this test with a message blaming SubtreeDelete for an upload
    # bug it had nothing to do with.
    assert_equal folder_node.node_id, user.nodes.present.find_by!(node_id: child).parent_node_id,
                 "the upload did not land under the folder -- this is an upload precondition, not " \
                 "part of the cascade being tested"

    subfolder = "#{journey_prefix}-cascade-sub"
    post library_folders_path, params: { name: subfolder, parent_node_id: folder_node.node_id },
                               as: :json
    assert_response :success, "create_folder (nested) failed: #{response.body}"
    subfolder_node = user.nodes.present.find_by!(name: subfolder, kind: "dir")
    assert_equal folder_node.node_id, subfolder_node.parent_node_id,
                 "the nested folder did not land under the top folder"

    grandchild = upload_through_ui("#{journey_prefix}-grandchild.stl",
                                   "grandchild #{journey_prefix}".b,
                                   parent_node_id: subfolder_node.node_id)
    assert_equal subfolder_node.node_id, user.nodes.present.find_by!(node_id: grandchild).parent_node_id,
                 "the grandchild upload did not land under the subfolder"

    delete file_path(folder_node.node_id)
    assert_redirected_to files_path
    assert_nil flash[:alert], "the directory delete was refused: #{flash[:alert]}"

    assert_not user.nodes.present.exists?(node_id: child),
               "SubtreeDelete must cascade to descendants -- an orphaned child is §14a's " \
               "recorded trap, and dir_deletable is true precisely because the server cascades"
    assert_not user.nodes.present.exists?(node_id: subfolder_node.node_id),
               "SubtreeDelete must cascade to the nested folder itself, not just the file " \
               "directly inside the top folder"
    assert_not user.nodes.present.exists?(node_id: grandchild),
               "SubtreeDelete must recurse past one level -- a delete that only tombstones DIRECT " \
               "children would pass a one-level fixture and still orphan " \
               "folder/subfolder/file.stl, which is exactly §14a's recorded trap"
  end

  # GAP (d), CONFIRMED, NOT ASSUMED. §14a: "chunk's undelete restores an orphan to the ROOT, and
  # restore order is NOT commutative -- Sync::Trash.restore(to_root: true) NULLs parent_node_id
  # when the parent is itself tombstoned... restoring a CHILD before its PARENT... permanently
  # scatters that folder's contents to the root." That is true of the EMBEDDED chunk adapter only,
  # and the reason is a PARAMETER, not a difference in the underlying restore logic: the one shared
  # implementation, `Sync::Trash.restore(user:, node_id:, to_root: false)`, defaults `to_root` to
  # FALSE (tinkerex-sync's app/services/sync/trash.rb:30). `FileLayer::Chunk#undelete` is the one
  # caller that overrides it -- `to_root: true`, unconditionally (tinkerex-sync's
  # app/services/file_layer/chunk.rb:497) -- because it runs in-process and is free to choose. The
  # STANDALONE server's own endpoint, `Sync::V1::TrashController#restore`, reads `to_root` from the
  # REQUEST instead of hardcoding it (`params[:to_root]`, defaulting false), and
  # `FileLayer::ChunkRemote#undelete` posts an EMPTY body (chunk_remote.rb:206:
  # `transport.post("/v1/trash/#{node_id}/restore", {})`) -- it never sends `to_root: true`. So on
  # chunk_remote the parent-still-tombstoned case hits the server's default, raises
  # `Sync::Trash::ParentDeleted`, and is rendered `409 {error: "parent_deleted"}`;
  # `Transport#interpret` maps 409 to `FileLayer::UnsupportedOperation` (transport.rb:104); this
  # app's `TrashController` rescue_from redirects to `trash_index_path` with alert "Couldn't
  # restore that item." (trash_controller.rb:40) instead of to `files_path` with the restore having
  # happened. THE RESTORE IS REFUSED, NOT SILENTLY SCATTERED -- a real divergence from §14a, and
  # arguably a safer failure mode than the one it documents (nothing is silently reorganized), but
  # it is not what §14a promises, and a caller written against that promise gets an unexplained 409
  # instead. Arc B's fix is a `to_root:` argument on the port's `undelete` verb, threaded through to
  # this POST's body. The assertions below are UNCHANGED from what §14a says SHOULD happen -- not
  # adjusted to match what was found, per this task's own rule, so the test fails at the first one
  # that diverges (the redirect target) rather than reaching the parent_node_id check at all.
  test "restoring a child before its parent restores it to the root, per §14a's restore-order trap" do
    skip_unless_remote_server
    user = sign_in
    folder = "#{journey_prefix}-restore-order"

    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success
    folder_node = user.nodes.present.find_by!(name: folder, kind: "dir")

    child = upload_through_ui("#{journey_prefix}-restore-child.stl",
                              "restore-order #{journey_prefix}".b, parent_node_id: folder_node.node_id)
    assert_equal folder_node.node_id, user.nodes.present.find_by!(node_id: child).parent_node_id,
                 "the upload did not land under the folder before the delete"

    delete file_path(folder_node.node_id)
    assert_redirected_to files_path
    assert_nil flash[:alert], "the directory delete was refused: #{flash[:alert]}"
    assert_not user.nodes.present.exists?(node_id: child),
               "the cascade should have tombstoned the child along with the folder"

    # THE CHILD, FIRST -- WHILE THE PARENT FOLDER IS STILL TOMBSTONED. The parent is deliberately
    # never restored in this test; that is the whole point of the ordering.
    post restore_trash_path(child)
    assert_redirected_to files_path
    assert_nil flash[:alert], "restoring the child was refused: #{flash[:alert]}"

    restored_child = user.nodes.present.find_by!(node_id: child)
    assert_nil restored_child.parent_node_id,
               "§14a: restoring a child before its still-tombstoned parent should scatter it to " \
               "the library ROOT (parent_node_id nil), never silently reunite it with a parent " \
               "that is not live -- got parent_node_id=#{restored_child.parent_node_id.inspect}"
  end

  # GAP (a). `refresh!` is called only from mkdir/move/delete/undelete/finalize_upload
  # (chunk_remote.rb:179,188,198,207,242) and ChangelogSync has no other caller in app/, lib/ or
  # config/. So a node another device pushed is invisible here until THIS app happens to write
  # something. Arc B's fix is a recurring per-user pull.
  test "a node created directly on the sync server becomes visible without a local write" do
    skip_unless_remote_server
    user = sign_in
    name = "#{journey_prefix}-from-elsewhere"
    transport = FileLayer::ChunkRemote::Transport.new(
      base_url: ENV.fetch("CHUNK_REMOTE_URL"), token: ENV.fetch("CHUNK_REMOTE_TOKEN")
    )
    node_id = SecureRandom.uuid
    transport.post("/v1/nodes", { node_id:, parent_node_id: nil, name:, mode: 0o755,
                                  mtime: (Time.current.to_f * 1e9).to_i })

    get files_path
    assert_response :success

    assert user.nodes.present.exists?(node_id:),
           "a node pushed by another device never reaches the mirror: there is no periodic pull " \
           "and no ActionCable subscription, so the maker UI cannot see it at all"
  end

  # GAP (b). port_writable is false on chunk_remote, so Maker::Addons::LibraryOutput#write takes
  # #write_chunk, which calls Sync::Storage::ChunkStore.current.put (library_output.rb:143) -- a
  # constant that does not exist in this process. Arc B's fix is a `put_chunk` port verb.
  test "an addon save writes its output into the library" do
    skip_unless_remote_server
    user = sign_in
    state = Maker::AddonState.create!(user:, addon_key: "journey", name: "j", data: {})

    files = [ { name: "#{journey_prefix}-out.svg", bytes: "<svg/>".b,
                content_type: "image/svg+xml", role: "output" } ]

    assert_nothing_raised do
      Maker::Addons::LibraryOutput.write(user:, state:, parent_node_id: nil, files:)
    end
    assert user.nodes.present.exists?(name: "#{journey_prefix}-out.svg"),
           "the addon's output never reached the library"
  end

  # GAP (c). LibraryBroadcast.batch degrades to a bare `yield` without the engine
  # (library_broadcast.rb:21), so N moves are N changelog pulls -- two WAN round-trips per file
  # inside a browser-facing request. Arc B's fix gives `batch` a real job on chunk_remote:
  # suppress the intermediate refresh! and pull once at the end.
  #
  # TEST BUG FIXED HERE: the plan's own source stubbed this with `ChangelogSync.stub(:new, ...)`
  # (Minitest::Mock's Object#stub). This repo is pinned to minitest 6.0.6 (Gemfile.lock), which
  # has dropped minitest/mock from the gem entirely -- `require "minitest/mock"` raises LoadError,
  # confirmed by hand, and no companion mock gem is bundled (grepping the whole test/ tree for
  # `.stub(` or `Minitest::Mock` turns up zero other uses, so this was never available, not merely
  # unused). `.stub` would have raised NoMethodError on `ChangelogSync`, failing for a reason that
  # says nothing about GAP (c). Replaced with a manual define_singleton_method/remove_method pair
  # that performs the identical interception -- count the call, forward to the real `new` -- and
  # restores the original in an ensure so the patch cannot leak into another test. It still drives
  # the real production path (LibraryBroadcast.batch -> ChunkRemote#move -> refresh! ->
  # ChangelogSync.new(...).call), so it genuinely counts changelog pulls; nothing about the
  # assertion below was softened.
  test "a batch of moves costs one changelog pull, not one per move" do
    skip_unless_remote_server
    user = sign_in
    folder = "#{journey_prefix}-batch"
    post library_folders_path, params: { name: folder }, as: :json
    assert_response :success
    dest = user.nodes.present.find_by!(name: folder, kind: "dir")

    ids = 3.times.map { |i| upload_through_ui("#{journey_prefix}-b#{i}.stl", "b#{i} #{journey_prefix}".b) }

    pulls = 0
    original_new = FileLayer::ChunkRemote::ChangelogSync.method(:new)
    FileLayer::ChunkRemote::ChangelogSync.define_singleton_method(:new) do |*a, **k|
      pulls += 1
      original_new.call(*a, **k)
    end

    begin
      LibraryBroadcast.batch(user) do
        ids.each { |id| FileLayer.current.move(user, node_id: id, new_parent_node_id: dest.node_id) }
      end
    ensure
      FileLayer::ChunkRemote::ChangelogSync.singleton_class.send(:remove_method, :new)
    end

    assert_equal 1, pulls,
                 "a batch of 3 moves pulled the changelog #{pulls} times; batch must defer the " \
                 "refresh so an eager project-intake sweep is not 2 WAN round-trips per file"
  end
end
