# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    class ChangelogSyncTest < ActiveSupport::TestCase
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

      setup do
        @user = User.create!(email: "applier@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
      end

      def entry(seq, node_id, name, kind: "file", parent: nil, deleted: false, size: nil, op: "put")
        e = { "seq" => seq, "op" => op, "node_id" => node_id,
              "node" => { "node_id" => node_id, "parent_node_id" => parent, "name" => name,
                          "kind" => kind, "deleted" => deleted, "mode" => nil, "mtime" => 1 } }
        e["version"] = { "version_id" => "v-#{seq}", "manifest_id" => "m", "size" => size } if size
        e
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
      test "a cursor below oldest_seq triggers a FULL RESYNC, not a patched-over hole" do
        @user.update_column(:remote_sync_cursor, 5)
        t = FakeTransport.new(pages: { 50 => [] }, oldest_seq: 50, head_seq: 50,
                              tree: [ { "node_id" => "srv", "parent_node_id" => nil, "name" => "kept.stl",
                                        "kind" => "file", "mode" => nil, "mtime" => 1,
                                        "version" => { "version_id" => "v1", "manifest_id" => "m", "size" => 9 } } ])
        result = sync(t)

        assert result.resynced, "a pruned gap must resync"
        assert_equal 50, @user.reload.remote_sync_cursor
        assert_equal 9, @user.nodes.find_by(node_id: "srv").size
      end

      test "a resync SWEEPS local rows the server no longer lists" do
        # Without this a resync is additive, and every file deleted while we were behind stays
        # visible forever -- the exact failure a resync exists to repair.
        @user.nodes.create!(node_id: "stale", name: "gone.stl", kind: "file")
        @user.update_column(:remote_sync_cursor, 5)
        t = FakeTransport.new(pages: { 50 => [] }, oldest_seq: 50, head_seq: 50,
                              tree: [ { "node_id" => "srv", "parent_node_id" => nil, "name" => "kept.stl",
                                        "kind" => "file", "mode" => nil, "mtime" => 1 } ])
        sync(t)

        assert @user.nodes.find_by(node_id: "stale").deleted, "a row the server never mentioned survived"
        assert_not @user.nodes.find_by(node_id: "srv").deleted
      end

      test "a FIRST sync is not a resync, though cursor 0 is below every oldest_seq" do
        t = FakeTransport.new(pages: { 0 => [ entry(1, "n1", "a.stl", size: 1) ] }, oldest_seq: 1, head_seq: 1)
        assert_not sync(t).resynced, "cursor 0 is the ordinary beginning, not a pruned gap"
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
    end
  end
end
