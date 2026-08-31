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
# whole file's behalf.
#
# IT WAS DELIBERATELY NOT A bin/ci GATE WHILE ANY OF THAT WAS TRUE -- test/ci_hygiene_test.rb
# asserts set equality between `bin/ci --list-ci` and ci.yml's gate jobs, so a red gate is a red
# main, and this suite was expected to be red until Arc B closed what it measured.
# .github/workflows/sync-contract.yml carried the signal instead, on the client-contract.yml
# precedent. Arc B closed all four gaps (CLAUDE.md §14a, and the record); the suite is 10/10
# against a real server, so it is now `config/ci.rb`'s `test-chunk-remote` gate and
# sync-contract.yml is gone -- one definition, same as every other gate.
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
    # TrashController's failure arms redirect to trash_index_path with an alert (:36, :59) while
    # success goes to files_path with a notice (:99), so the destination alone would discriminate
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

  # GAP (d), CLOSED -- AND THIS TEST'S OWN ASSERTIONS ARE WHAT CHANGE, PER THE ONE EXCEPTION THIS
  # ARC'S RULES CARVE OUT FOR THEMSELVES. §14a used to document: "chunk's undelete restores an
  # orphan to the ROOT, and restore order is NOT commutative -- Sync::Trash.restore(to_root: true)
  # NULLs parent_node_id when the parent is itself tombstoned... restoring a CHILD before its
  # PARENT... permanently scatters that folder's contents to the root." That was true of the
  # EMBEDDED chunk adapter only, and the reason was a PARAMETER, not a difference in the underlying
  # restore logic: the one shared implementation, `Sync::Trash.restore(user:, node_id:, to_root:
  # false)`, defaults `to_root` to FALSE (tinkerex-sync's app/services/sync/trash.rb).
  # `FileLayer::Chunk#undelete` was the one caller overriding it -- `to_root: true`,
  # unconditionally -- because it ran in-process and was free to choose, while
  # `FileLayer::ChunkRemote#undelete` posts an EMPTY body (chunk_remote.rb:
  # `transport.post("/v1/trash/#{node_id}/restore", {})`) and never sent `to_root: true`. So on
  # chunk_remote the parent-still-tombstoned case always hit the server's strict default, raised
  # `Sync::Trash::ParentDeleted`, and came back `409 {error: "parent_deleted"}` -- REFUSED, not
  # scattered. Running THIS test against a real standalone server is what surfaced that the two
  # adapters disagreed; a conformance corpus in `tinkerex-sync` now pins both arms of the server's
  # own behaviour (`to_root` true and false), and this repo's job was only ever to pick one.
  #
  # THE DECISION, ONCE THE DIVERGENCE SURFACED: converge on the SAFER answer, not the DOCUMENTED
  # one. `Chunk#undelete` no longer passes `to_root: true`, so chunk now refuses too -- see
  # CLAUDE.md 14a for the full argument (the old bullet's own evidence, that a bottom-up restore is
  # the mainline case since a cascading delete and permanently unrecoverable once taken, is what
  # overturned the bullet itself). That makes the assertions this test used to pin -- a silent
  # scatter to the root -- describe behaviour the code no longer has, which is exactly what this
  # file's own header and Arc B's worklist forbid changing a test to paper over. This is the
  # DECLARED exception: the assertions below are REWRITTEN, not relaxed, to pin the refusal and the
  # recoverable path around it (restore the folder, then the child) in place of the scatter.
  test "restoring a child before its tombstoned parent is refused, per §14a's reversed rule" do
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

    # THE CHILD, FIRST -- WHILE THE PARENT FOLDER IS STILL TOMBSTONED. This used to succeed and
    # scatter the child to the root; it is now REFUSED. TrashController's UnsupportedOperation
    # rescue redirects to trash_index_path (never files_path -- that is success's own redirect)
    # with an alert that names the action, not just the failure.
    post restore_trash_path(child)
    assert_redirected_to trash_index_path
    assert_match(/folder/i, flash[:alert],
                 "the refusal must tell the user to restore the folder, not merely that it failed " \
                 "-- got #{flash[:alert].inspect}")
    assert_not user.nodes.present.exists?(node_id: child),
               "a refused restore must not half-apply -- the child stays tombstoned"

    # FOLLOW THE REDIRECT, THE WAY A BROWSER WOULD -- and not merely for realism. Flash is
    # designed to survive exactly ONE further request so the page it redirects to can display it;
    # chaining the next POST directly (as this test used to) leaves that alert un-consumed, and it
    # would still read back non-nil after the FOLDER restore below even though that response never
    # set it -- a false failure this test hit once, about the test's own flash bookkeeping rather
    # than about anything TrashController does.
    get trash_index_path
    assert_response :success

    # THE FOLDER, THEN THE CHILD -- THE ONLY ORDER THAT NOW SUCCEEDS AT ALL. Restoring the parent
    # first used to be merely the order that happened to preserve structure; the other order is
    # refused outright now, so this is the only path back to a live child.
    post restore_trash_path(folder_node.node_id)
    assert_redirected_to files_path
    assert_nil flash[:alert], "restoring the folder was refused: #{flash[:alert]}"

    post restore_trash_path(child)
    assert_redirected_to files_path
    assert_nil flash[:alert],
               "restoring the child was refused even once its folder was back: #{flash[:alert]}"

    restored_child = user.nodes.present.find_by!(node_id: child)
    assert_equal folder_node.node_id, restored_child.parent_node_id,
                 "parent-first restore must reunite the child with its actual folder, never " \
                 "scatter it to the root -- got parent_node_id=#{restored_child.parent_node_id.inspect}"
  end

  # GAP (a), RE-SCOPED 2026-08-24. The original version of this test asserted that a bare
  # `get files_path` -- a PLAIN READ -- made a node pushed by another device visible. No permitted
  # implementation can satisfy that assertion, and trying to satisfy it anyway is what exposed the
  # real defect underneath it:
  #
  #   - CLAUDE.md §2: "the WAN is never in the metadata path." §14a's entire claim for
  #     chunk_remote is that reads answer from the LOCALLY-MIRRORED `nodes` table *so that* §2
  #     becomes true of the maker app for the first time (chunk_remote.rb's own header: "READS ARE
  #     LOCAL SQL, WRITES GO OVER THE WIRE"). A page load that reaches the sync server to answer a
  #     read would violate that on every request, not just this one -- so the old assertion could
  #     only be made to pass by an implementation the architecture exists to forbid.
  #   - The staleness this test now pins is therefore §2 being HONOURED, not a bug: the mirror is
  #     deliberately behind the server between pulls, and a plain read must never close that gap
  #     itself.
  #   - The actual freshness mechanism is FileLayer::RemoteChangelogPullJob (Arc B), scheduled from
  #     config/recurring.yml's `remote_changelog_pull` entry and covered by its own unit test
  #     (test/jobs/file_layer/remote_changelog_pull_job_test.rb, including the chunk_remote-only
  #     gate, mutation-checked in both directions). Its SCHEDULING is a deployment concern this
  #     suite cannot exercise: test/recurring_schedule_test.rb's own header records that
  #     "config/recurring.yml is loaded by the Solid Queue SUPERVISOR, not by the Rails process the
  #     suite boots" -- no such Supervisor runs under `bin/rails test`, so nothing here can observe
  #     the schedule firing on its own. What this suite CAN and SHOULD prove is the mechanism
  #     itself: invoking the pull the scheduler performs in production makes a remotely-created
  #     node visible, both in the mirror and on the rendered page.
  #   - `refresh!` is still called only from mkdir/move/delete/undelete/finalize_upload
  #     (chunk_remote.rb:179,188,198,207,242), and ChangelogSync's only OTHER caller anywhere in
  #     app/, lib/ or config/ is this job -- so a node another device pushed stays invisible until
  #     either this app writes something of its own or the recurring pull runs. The real fix for
  #     LATENCY (as opposed to eventual correctness) is a sync -> maker webhook or an ActionCable
  #     subscription to the remote host's own broadcast -- still out of scope.
  #
  # Do not "fix" this back to asserting that a bare page load refreshes the mirror -- that is the
  # assertion this rewrite exists to retire, not a property to restore.
  test "a node created directly on the sync server becomes visible without a local write" do
    skip_unless_remote_server
    user = sign_in

    # FORCE PROVISIONING FIRST. Arc C: this test simulates "the SAME maker user's other device"
    # pushing a node straight to the sync server, which now means authenticating as THIS user's
    # OWN sync_device_token, never the bootstrap CHUNK_REMOTE_TOKEN (that credential belongs to a
    # different remote user entirely since Task 4 -- using it here would silently push the node
    # into the WRONG library, and the pull below would then correctly never see it, for a reason
    # that has nothing to do with what this test exists to prove). Reads never provision
    # (chunk_remote.rb's own header: "READS ARE LOCAL SQL"), so `sign_in` alone leaves
    # sync_device_token nil -- a throwaway folder create is the cheapest write available.
    post library_folders_path, params: { name: "#{journey_prefix}-provision" }, as: :json
    assert_response :success, "the throwaway folder used to force provisioning failed: #{response.body}"
    user.reload
    assert user.sync_device_token.present?, "provisioning did not run -- nothing to build the " \
           "'other device' transport from below"

    name = "#{journey_prefix}-from-elsewhere"
    transport = FileLayer::ChunkRemote::Transport.new(
      base_url: ENV.fetch("CHUNK_REMOTE_URL"), token: user.sync_device_token
    )
    node_id = SecureRandom.uuid
    transport.post("/v1/nodes", { node_id:, parent_node_id: nil, name:, mode: 0o755,
                                  mtime: (Time.current.to_f * 1e9).to_i })

    assert_not user.nodes.present.exists?(node_id:),
               "a plain read must NOT reach the WAN (CLAUDE.md §2) -- a node pushed elsewhere is " \
               "correctly invisible until the mirror is next pulled; if this assertion is false, " \
               "something has put a synchronous server call on a read path, which is the " \
               "regression this test exists to catch"

    FileLayer::RemoteChangelogPullJob.perform_now(user_id: user.id)

    assert user.nodes.present.exists?(node_id:),
           "the recurring pull (config/recurring.yml's remote_changelog_pull in production; " \
           "invoked directly here because bin/rails test never runs the Solid Queue Supervisor " \
           "that would fire it on a schedule) must bring a node pushed by another device into " \
           "the mirror"

    get files_path
    assert_response :success
    assert_includes response.body, name,
                     "the mirror has the node, but the rendered page does not show it"
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
