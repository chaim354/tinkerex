# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    # THE METADATA READS, WHICH ANSWER FROM LOCAL SQL AND NEVER TOUCH THE WIRE.
    #
    # The adapter is constructed with NO transport on purpose in most of these: if any of stat,
    # stat_all or trashed reached for one it would raise KeyError on the missing CHUNK_REMOTE_URL,
    # so "no wire" is enforced by construction rather than asserted in a comment.
    class ReadsTest < ActiveSupport::TestCase
      setup do
        @user = User.create!(email: "reads@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
        @adapter = ChunkRemote.new
      end

      def node!(node_id, name, kind: "file", size: nil, version: nil, deleted: false, mtime: 1)
        @user.nodes.create!(node_id:, name:, kind:, size:, mtime:,
                            current_version_id: version, deleted:)
      end

      test "stat describes a mirrored file, with the version id as its content token" do
        node!("n1", "a.stl", size: 42, version: "v-7", mtime: 1_700_000_000_000_000_000)
        info = @adapter.stat(@user, node_id: "n1")

        assert_equal [ "n1", "a.stl", "file", 42 ], [ info.node_id, info.name, info.kind, info.size ]
        assert_equal "v-7", info.content_token,
                     "content_token must be the version id, as Chunk's is -- maker_previews keys on it"
        assert_equal 1_700_000_000_000_000_000, info.mtime
      end

      test "stat raises NotFound for an unknown node" do
        assert_raises(FileLayer::NotFound) { @adapter.stat(@user, node_id: "nope") }
      end

      test "stat raises NotFound for a node the changelog marked deleted" do
        node!("gone", "gone.stl", deleted: true)
        assert_raises(FileLayer::NotFound) { @adapter.stat(@user, node_id: "gone") }
      end

      test "stat_all answers exactly what stat answers" do
        node!("n1", "a.stl", size: 1, version: "v1")
        node!("n2", "b.stl", size: 2, version: "v2")

        infos = @adapter.stat_all(@user, node_ids: %w[n1 n2])
        %w[n1 n2].each { |id| assert_equal @adapter.stat(@user, node_id: id), infos[id] }
      end

      test "stat_all OMITS what stat raises NotFound for -- an absent key, never a raise" do
        # A bulk caller holds a list; a row tombstoned mid-page must not 404 the whole page.
        node!("live", "a.stl", size: 1)
        node!("dead", "b.stl", deleted: true)

        infos = @adapter.stat_all(@user, node_ids: %w[live dead unknown])
        assert_equal %w[live], infos.keys
      end

      test "stat_all costs a number of queries that does not grow with the list" do
        20.times { |i| node!("n#{i}", "f#{i}.stl", size: i) }

        few = @adapter.method(:stat_all)
        count = ->(ids) {
          n = 0
          sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            n += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
          end
          few.call(@user, node_ids: ids)
          ActiveSupport::Notifications.unsubscribe(sub)
          n
        }
        count.call(%w[n0]) # warm
        assert_equal count.call(%w[n0 n1]), count.call((0...20).map { |i| "n#{i}" }),
                     "stat_all's query count grew with the list"
      end

      test "stat_all is ONE query here, where Chunk needs two" do
        # Not a literal pinned for its own sake: it is the payoff of ChangelogSync recording size on
        # the node. Chunk reads sizes from `versions` because nodes.size is NULL there.
        node!("n1", "a.stl", size: 1, version: "v1")
        n = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          n += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
        end
        @adapter.stat_all(@user, node_ids: %w[n1])
        ActiveSupport::Notifications.unsubscribe(sub)
        assert_equal 1, n
      end

      test "trashed lists what the changelog marked deleted, and never a live file" do
        node!("live", "here.stl", size: 1)
        node!("binned", "gone.stl", size: 9, deleted: true)

        entries = @adapter.trashed(@user)
        assert_equal %w[binned], entries.map(&:node_id)
        assert_equal 9, entries.first.size
      end

      test "the reads never touch the wire" do
        # Constructed with no transport: reaching for one raises KeyError on CHUNK_REMOTE_URL, so
        # this is enforced rather than asserted. A sync server that is down must make the library
        # STALE, not broken -- that is what local-first means (§2).
        node!("n1", "a.stl", size: 1)
        assert_nothing_raised do
          @adapter.stat(@user, node_id: "n1")
          @adapter.stat_all(@user, node_ids: %w[n1])
          @adapter.trashed(@user)
        end
      end

      test "byte reads now exist, and the write refusal still does" do
        # This asserted read/download were ABSENT until the manifest store landed. Kept, inverted,
        # rather than deleted: the pair is what says which verbs this adapter has, and `write` must
        # go on refusing forever -- chunk-family backends are not port_writable, and a byte write
        # would push bytes through Rails (§15).
        assert @adapter.respond_to?(:read)
        assert @adapter.respond_to?(:download)
        assert_raises(NotImplementedError) do
          @adapter.write(@user, parent_node_id: nil, name: "x.stl", io: StringIO.new("x"))
        end
      end
    end
  end
end
