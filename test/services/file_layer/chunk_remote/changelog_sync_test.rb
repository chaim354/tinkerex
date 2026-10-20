# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    class ChangelogSyncTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper
      # A transport that answers canned pages and RECORDS what was asked, so paging and cursor
      # advancement are asserted on the requests rather than inferred from the result.
      class FakeTransport
        attr_reader :asked

        def initialize(pages: {}, tree: [], head_seq: 0, oldest_seq: 1)
          @pages = pages
          @tree = tree
          @head_seq = head_seq
          @oldest_seq = oldest_seq
          @asked = []
        end

        def get(path, params = {})
          @asked << [ path, params ]
          case path
          when "/v1/changes"
            { "changes" => @pages.fetch(params[:since], []),
              "head_seq" => @head_seq, "oldest_seq" => @oldest_seq }
          when "/v1/tree"
            { "nodes" => @tree, "head_seq" => @head_seq, "next_after_id" => 0 }
          end
        end
      end

      # FakeTransport plus ONE REFUSAL: a SECOND /v1/tree raises rather than answering. That is
      # load-bearing, not decoration. Mutation-testing this file once HUNG rather than failed (see
      # "a changelog that does not advance" below), and a gap check re-asked per page against a
      # server whose `oldest_seq` stays above every cursor is the same shape -- it resyncs forever,
      # so the plain fake would spin and the mutation-check would report nothing at all. This turns
      # that hang into a red test in milliseconds.
      class ResyncCountingTransport < FakeTransport
        def get(path, params = {})
          if path == "/v1/tree"
            @tree_calls = (@tree_calls || 0) + 1
            raise FileLayer::FetchError, "resynced more than once" if @tree_calls > 1
          end
          super
        end
      end

      setup do
        @user = User.create!(email: "applier@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
      end

      def entry(seq, node_id, name, kind: "file", parent: nil, deleted: false, size: nil, op: "put")
        e = { "seq" => seq, "op" => op, "node_id" => node_id,
              "node" => { "node_id" => node_id, "parent_node_id" => parent, "name" => name,
                          "kind" => kind, "deleted" => deleted, "mode" => nil, "mtime" => 1 } }
        # `version` AND `manifest` TRAVEL TOGETHER, AS THE SERVER SENDS THEM (sync-protocol.md §8.3;
        # `Change` in tinkerex-sync's services/changes.rs): both on a `put` whose version still
        # resolves, neither otherwise -- and the manifest rides on the ENTRY, beside `node`.
        if size
          e["version"] = { "version_id" => "v-#{seq}", "manifest_id" => "m", "size" => size }
          e["manifest"] = [ { "hash" => "h-#{seq}", "offset" => 0, "length" => size } ]
        end
        e
      end

      # A /v1/tree NODE, IN THE SHAPE THE SERVER SENDS IT (sync-protocol.md §8.4; `TreeNode` in
      # tinkerex-sync's services/tree.rs): a file's content lies FLAT on the node -- `version_id`,
      # `size`, `manifest` -- and there is no `deleted`, because the tree lists live nodes only. Keys
      # a node has no value for are ABSENT, as the server omits them. The one tree fake here that
      # carried content once nested a `version` object no tree has ever sent -- the applier's own
      # misreading -- so the only test of the resync arm confirmed the bug instead of catching it
      # (CLAUDE.md §14e); the other two carried no content at all.
      def tree_node(node_id, name, kind: "file", parent: nil, size: nil, version_id: "v-#{node_id}",
                    manifest: [ { "hash" => "h-#{node_id}", "offset" => 0, "length" => size } ])
        n = { "node_id" => node_id, "parent_node_id" => parent, "name" => name,
              "kind" => kind, "mode" => nil, "mtime" => 1 }
        n.merge!("version_id" => version_id, "size" => size, "manifest" => manifest) if size
        n
      end

      def manifest_of(version_id)
        RemoteManifestChunk.where(user: @user).for_version(version_id).pluck(:chunk_hash, :offset, :length)
      end

      def sync(transport) = ChangelogSync.new(@user, transport:).call

      test "a first pull applies entries and advances the cursor" do
        t = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", size: 12) ] }, head_seq: 1)
        result = sync(t)

        assert_equal 1, result.applied
        assert_equal 1, @user.reload.remote_sync_cursor
        node = @user.nodes.find_by(node_id: "n1")
        assert_equal "a.stl", node.name
        assert_not node.deleted
      end

      test "size is recorded ON THE NODE, which is what makes stat_all one query" do
        # nodes.size is NULL on chunk -- only the share/s3 scan ever wrote it, and Chunk#stat_all
        # pays a second query to `versions` for what this loop records once, at apply time.
        t = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", size: 4096) ] }, head_seq: 1)
        sync(t)
        assert_equal 4096, @user.nodes.find_by(node_id: "n1").size
      end

      # THE INCREMENTAL ARM'S HALF OF THE CONTRACT THE RESYNC ARM BROKE, pinned because the fix
      # moved it: the manifest used to reach the applier through an instance variable set around
      # the call, and is now an argument. A `put` carries its content at the ENTRY level -- `version`
      # beside `node`, `manifest` beside both (sync-protocol.md §8.3) -- and every other op omits
      # both keys, so the move after it must leave the content it landed exactly as it was.
      test "a change entry lands its version, size and manifest, and a later move keeps them" do
        t = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", size: 12),
                                              entry(2, "n1", "moved.stl", parent: "dirB", op: "move") ] },
                              head_seq: 2)
        sync(t)

        node = @user.nodes.find_by(node_id: "n1")
        assert_equal [ "moved.stl", "v-1", 12 ], [ node.name, node.current_version_id, node.size ]
        assert_equal [ [ "h-1", 0, 12 ] ], manifest_of("v-1")
      end

      test "every op is one upsert -- a move is the node's new state, not a special case" do
        # BOTH IN ONE PAGE, because that is what the server returns: a page shorter than the limit
        # means caught up, so the loop rightly stops rather than asking again. An earlier version of
        # this test put one entry per page and failed -- the test was modelling the wire wrong.
        t = FakeTransport.new(pages: {
          0 => [ entry(1, "n1", "a.stl", parent: "dirA", size: 1),
                 entry(2, "n1", "renamed.stl", parent: "dirB", size: 1, op: "move") ]
        }, head_seq: 2)
        sync(t)

        node = @user.nodes.find_by(node_id: "n1")
        assert_equal [ "renamed.stl", "dirB" ], [ node.name, node.parent_node_id ]
        assert_equal 2, @user.reload.remote_sync_cursor
      end

      test "a delete entry marks the local row deleted" do
        t = FakeTransport.new(pages: {
          0 => [ entry(1, "n1", "a.stl", size: 1),
                 entry(2, "n1", "a.stl", deleted: true, op: "delete") ]
        }, head_seq: 2)
        sync(t)
        assert @user.nodes.find_by(node_id: "n1").deleted
      end

      test "an entry with NO node payload still deletes, and invents no row" do
        t = FakeTransport.new(pages: { 0 => [ { "seq" => 1, "op" => "delete", "node_id" => "ghost" } ] },
                              head_seq: 1)
        sync(t)
        assert_nil @user.nodes.find_by(node_id: "ghost"), "a nameless row was invented from a node_id"
      end

      test "paging continues while a full page comes back" do
        full = (1..ChangelogSync::PAGE).map { |i| entry(i, "n#{i}", "f#{i}.stl", size: 1) }
        t = FakeTransport.new(pages: { 0 => full, ChangelogSync::PAGE => [ entry(9999, "last", "z.stl", size: 1) ] },
                              head_seq: 9999)
        result = sync(t)

        assert_equal ChangelogSync::PAGE + 1, result.applied
        assert_equal 9999, @user.reload.remote_sync_cursor
        assert_includes t.asked.map(&:last).map { |p| p[:since] }, ChangelogSync::PAGE
      end

      # ── the pruned gap ────────────────────────────────────────────────────────────────────────

      # THE REQUEST COUNT, WHICH NOTHING PINNED WHILE IT WAS WRONG. The gap check used to open with
      # its own `limit: 1` GET, so the overwhelmingly common pull -- the one that finds nothing --
      # cost TWO WAN round trips for one body's worth of data: `oldest_seq` and `head_seq` are
      # computed independently of `since`/`limit` and ride on every /v1/changes response.
      #
      # The WHOLE `asked` array is asserted rather than its length, so this pins three things at
      # once: exactly one request, that it is /v1/changes, and that it is PAGE-sized rather than a
      # probe. Restoring the probe fails it on both the length and the `limit: 1` element.
      test "a no-op pull issues EXACTLY ONE /v1/changes request, PAGE-sized" do
        t = FakeTransport.new(pages: {}, head_seq: 0, oldest_seq: 1)
        sync(t)

        assert_equal [ [ "/v1/changes", { since: 0, limit: ChangelogSync::PAGE } ] ], t.asked,
                     "the gap fields ride on the page response; a separate probe is a second WAN " \
                     "round trip for data this body already carries"
      end

      test "a cursor below oldest_seq triggers a FULL RESYNC, not a patched-over hole" do
        @user.update_column(:remote_sync_cursor, 5)
        t = FakeTransport.new(pages: { 50 => [] }, oldest_seq: 50, head_seq: 50,
                              tree: [ tree_node("srv", "kept.stl", size: 9) ])
        result = sync(t)

        assert result.resynced, "a pruned gap must resync"
        assert_equal 50, @user.reload.remote_sync_cursor
        assert_equal 9, @user.nodes.find_by(node_id: "srv").size
      end

      # THE DEFECT THE CORRECTED FAKES EXPOSED. A resync is the repair for a mirror that fell behind
      # a pruned changelog, so the files it must get right are exactly the ones the mirror MISSED:
      # one created while it was behind (no local row at all) and one whose content changed (the row
      # still names the old version). The applier once looked for a nested `version` no tree sends,
      # so both came through with their PLACE repaired and their CONTENT not -- the new file listed
      # at 0 bytes with no version (every read a NotFound), the changed one still naming, sizing and
      # serving its old bytes -- with no error anywhere, and nothing to heal it before the next put.
      test "a resync lands each file's version, size and manifest -- a new file AND a changed one" do
        @user.nodes.create!(node_id: "changed", name: "b.stl", kind: "file", current_version_id: "v-old", size: 3)
        @user.update_column(:remote_sync_cursor, 5)
        two_chunks = [ { "hash" => "h-a", "offset" => 0, "length" => 4 },
                       { "hash" => "h-b", "offset" => 4, "length" => 5 } ]
        t = FakeTransport.new(pages: { 50 => [] }, oldest_seq: 50, head_seq: 50,
                              tree: [ tree_node("new", "a.stl", size: 9, manifest: two_chunks),
                                      tree_node("changed", "b.stl", size: 7) ])
        assert sync(t).resynced, "a pruned gap must resync"

        fresh = @user.nodes.find_by(node_id: "new")
        assert_equal [ "v-new", 9 ], [ fresh.current_version_id, fresh.size ],
                     "a file created while the mirror was behind came through with no content"
        assert_equal [ [ "h-a", 0, 4 ], [ "h-b", 4, 5 ] ], manifest_of("v-new")

        changed = @user.nodes.find_by(node_id: "changed")
        assert_equal [ "v-changed", 7 ], [ changed.current_version_id, changed.size ],
                     "a file changed while the mirror was behind still names its old version"
        assert_equal [ [ "h-changed", 0, 7 ] ], manifest_of("v-changed")
      end

      test "a resync SWEEPS local rows the server no longer lists" do
        # Without this a resync is additive, and every file deleted while we were behind stays
        # visible forever -- the exact failure a resync exists to repair.
        @user.nodes.create!(node_id: "stale", name: "gone.stl", kind: "file")
        @user.update_column(:remote_sync_cursor, 5)
        t = FakeTransport.new(pages: { 50 => [] }, oldest_seq: 50, head_seq: 50,
                              tree: [ tree_node("srv", "kept.stl", size: 9) ])
        sync(t)

        assert @user.nodes.find_by(node_id: "stale").deleted, "a row the server never mentioned survived"
        assert_not @user.nodes.find_by(node_id: "srv").deleted
      end

      test "a FIRST sync is not a resync, though cursor 0 is below every oldest_seq" do
        t = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", size: 1) ] }, oldest_seq: 1, head_seq: 1)
        assert_not sync(t).resynced, "cursor 0 is the ordinary beginning, not a pruned gap"
      end

      # THE GAP IS ASKED ONCE, NOT PER PAGE -- the hazard the fold introduces if it is written
      # carelessly. `oldest_seq` need not fall below the cursor a resync lands on: an emptied
      # changelog reports `head_seq + 1` (docs/sync-protocol.md), which is ABOVE it, so a per-page
      # check would resync, re-check, resync... forever, applying nothing and holding the job.
      test "the pruned-gap check is evaluated ONCE, so an oldest_seq above the post-resync cursor cannot resync forever" do
        @user.update_column(:remote_sync_cursor, 5)
        t = ResyncCountingTransport.new(pages: { 50 => [] }, oldest_seq: 51, head_seq: 50,
                                        tree: [ tree_node("srv", "kept.stl", size: 9) ])
        sync(t)

        assert_equal 1, t.asked.count { |path, _| path == "/v1/tree" },
                     "a per-page gap check resyncs forever against a server reporting oldest_seq " \
                     "above every cursor"
      end

      test "a changelog that does not advance raises instead of looping forever" do
        # FOUND BY MUTATION-TESTING, WHICH HUNG RATHER THAN FAILED. Freezing the cursor write turned
        # the pull into an infinite loop: a FULL page keeps the short-page break false, so it
        # refetched `since: 0` forever, holding a request or a job with no error anywhere. A server
        # that replays a page must fail loudly and fast.
        full = (1..ChangelogSync::PAGE).map { |i| entry(i, "n#{i}", "f#{i}.stl", size: 1) }
        replaying = Class.new do
          def initialize(p) = @p = p
          def get(path, _params = {})
            # Always the same page, whatever the cursor says.
            path == "/v1/changes" ? { "changes" => @p, "head_seq" => 1, "oldest_seq" => 1 } : { "nodes" => [] }
          end
        end.new(full)

        # It applies the page once (advancing the cursor to 500), asks again, gets the SAME page,
        # and refuses rather than spinning.
        assert_raises(FileLayer::FetchError) { ChangelogSync.new(@user, transport: replaying).call }
      end

      # ── the shape cannot drift away from the server's ─────────────────────────────────────────
      test "it applies REAL Sync::Changes output, so the wire shape cannot drift" do
        skip "needs the engine for a real changelog" unless defined?(Sync)

        author = User.create!(email: "author@example.com", password: "correct horse battery staple",
                              confirmed_at: Time.current)
        seq = author.next_seq!
        author.nodes.create!(node_id: "real1", name: "real.stl", kind: "file")
        author.changelog_entries.create!(seq:, op: "mkdir", node_id: "real1")

        payload = Sync::Changes.call(user: author, since: 0).as_json
        transport = Class.new do
          def initialize(p) = @p = p
          def get(path, _params = {}) = path == "/v1/changes" ? @p : { "nodes" => [] }
        end.new(payload)

        # One page, so the loop's "short page ends it" branch closes it out.
        ChangelogSync.new(@user, transport:).call
        assert_equal "real.stl", @user.nodes.find_by(node_id: "real1")&.name,
                     "the applier did not understand a payload the server actually produces"
      end

      # ---- the device-push project-intake nudge (CLAUDE.md §12.10) -------------------------------
      # `Maker::ProjectIntakeJob.nudge` was CALLERLESS from the engine extraction until 2026-08-25:
      # a file pushed by a device waited up to 15 minutes for the periodic sweep. The pull is where
      # this app learns about such a file, so the nudge is fired here. These pin the three things
      # that make that cheap and correct: it fires for a project folder, it does NOT fire for a
      # folder no project owns, and it asks the database ONCE per pull however many files landed.

      test "a device-pushed file under a project folder nudges the intake sweep" do
        project = @user.maker_projects.create!(name: "Harbor", folder_node_id: "proj-folder")
        transport = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", parent: "proj-folder") ] },
                                      head_seq: 1)

        assert_enqueued_with(job: Maker::ProjectIntakeJob) do
          ChangelogSync.new(@user, transport:).call
        end
        assert project.persisted?
      end

      test "a device-pushed file in a folder NO project owns nudges nothing" do
        transport = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", parent: "some-folder") ] },
                                      head_seq: 1)

        assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
          ChangelogSync.new(@user, transport:).call
        end
      end

      test "a directory and a tombstone are not arrivals, so neither nudges" do
        @user.maker_projects.create!(name: "Harbor", folder_node_id: "proj-folder")
        transport = FakeTransport.new(
          pages: { 0 => [ entry(1, "d1", "sub", kind: "dir", parent: "proj-folder"),
                          entry(2, "n2", "gone.stl", parent: "proj-folder", deleted: true) ] },
          head_seq: 2
        )

        assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
          ChangelogSync.new(@user, transport:).call
        end
      end

      test "many files in one pull ask the projects table ONCE, not once per file" do
        @user.maker_projects.create!(name: "Harbor", folder_node_id: "proj-folder")
        entries = (1..25).map { |i| entry(i, "n#{i}", "f#{i}.stl", parent: "proj-folder") }
        transport = FakeTransport.new(pages: { 0 => entries }, head_seq: 25)

        queries = 0
        counter = ->(_n, _s, _f, _i, payload) do
          queries += 1 if payload[:sql]&.include?("maker_projects")
        end
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          ChangelogSync.new(@user, transport:).call
        end

        assert_equal 1, queries,
                     "expected ONE maker_projects lookup for the whole pull, got #{queries} -- " \
                     "the per-node form would pay one per entry to enqueue a job " \
                     "limits_concurrency discards anyway"
      end
    end
  end
end
