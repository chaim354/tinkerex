require "test_helper"

module Maker
  class LibraryFolderTest < ActiveSupport::TestCase
    # Same idiom as test/integration/web/page_query_budget_test.rb's count_queries, duplicated
    # rather than shared: that file's copy is INTEGRATION-test shaped (asserts on a rendered
    # page), this one's caller measures a plain service call, and the two have no natural common
    # home that isn't a bigger refactor than this guard is worth.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # THE REGRESSION THIS GUARDS: ensure_segment briefly called FileLayer.current.mkdir
    # unconditionally, for every segment, including one already in the catalog — correct (every
    # adapter's mkdir is independently idempotent), but not free: the caller then re-fetched with
    # find_by!(node_id:) on top of whatever the adapter looked up internally. Measured on a
    # 2-segment already-exists walk: 2 queries -> 4 on chunk, 2 -> 7 on share/s3 (whose own mkdir
    # does more internal work — leaf!/parent_dir_rel!/observable! — before its idempotence check
    # even runs). This lands on synchronous, browser-facing paths that call ensure_path!/
    # create_child! repeatedly in one request: ModelsController#ensure_folders (once per unique
    # subfolder in a bulk import) and Maker::ProjectIntake#place (inside the eager nudge, whose
    # own EAGER_MAX_MOVES cap already treats latency here as tight enough to bound separately).
    #
    # ASSERTED AGAINST A MEASURED BASELINE, NOT A LITERAL — CLAUDE.md 15 / page_query_budget_
    # test.rb's own rule — and the reason is sharper here than "a literal is fragile": the
    # regression above is UNIFORMLY 2x on chunk (2, 4, 6 for 1/2/3 segments), so a self-consistency
    # check (does cost scale linearly with segment count?) would stay GREEN under it — chunk's
    # regressed cost is perfectly proportional, just proportional to the wrong constant. What
    # actually pins the constant is comparing against an INDEPENDENT oracle: the raw query
    # ensure_segment's short-circuit itself performs, measured directly rather than assumed. That
    # oracle costs exactly one query by construction and does not change when ensure_segment's
    # own implementation regresses, which is what lets it catch a regression a same-code
    # self-consistency check cannot.
    def assert_already_existing_path_costs_one_query_per_segment
      Maker::LibraryFolder.ensure_path!(@user, %w[q1 q2 q3]) # seed all three, for real, once

      baseline = count_queries do
        @user.nodes.present.find_by(parent_node_id: nil, name: "q1", kind: "dir")
      end

      one   = count_queries { Maker::LibraryFolder.ensure_path!(@user, %w[q1]) }
      three = count_queries { Maker::LibraryFolder.ensure_path!(@user, %w[q1 q2 q3]) }

      assert_equal baseline, one,
                   "walking one already-existing segment cost #{one} queries; the short-circuit's " \
                   "own lookup alone costs #{baseline} — anything more means the port was reached " \
                   "for a segment that already existed"
      assert_equal baseline * 3, three,
                   "walking three already-existing segments cost #{three} queries, not " \
                   "#{baseline * 3} (#{baseline} per segment) — cost must stay exactly " \
                   "proportional, never grow, as more of the path already exists"
    end

    # Chunk branch: real chunk backend; folders created via Sync::Mutation (changelog entries).
    class ChunkBranch < LibraryFolderTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "lf-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
      end

      test "ensure_path! creates nested dirs via sync-mutation, idempotently" do
        leaf = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal "dir", leaf.kind
        assert_equal "desk-lamp", leaf.name
        root = @user.nodes.present.find_by!(name: "Projects", parent_node_id: nil, kind: "dir")
        assert_equal root.node_id, leaf.parent_node_id
        assert @user.changelog_entries.exists?(op: "mkdir", node_id: leaf.node_id),
               "chunk mkdir must go through the sync engine (a changelog entry)"

        again = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal leaf.node_id, again.node_id, "idempotent — same leaf, no duplicate"
        assert_equal 1, @user.nodes.where(name: "Projects", parent_node_id: nil, kind: "dir").count
      end

      test "walking an already-existing path costs one query per segment, never the port" do
        assert_already_existing_path_costs_one_query_per_segment
      end
    end

    # Share branch: port_writable → FileLayer.current.mkdir (also exercises the s3 code path).
    class ShareBranch < LibraryFolderTest
      setup do
        @root = Dir.mktmpdir("lf-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "lfs-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      test "ensure_path! walks via the port's mkdir (share)" do
        leaf = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal "Projects/desk-lamp", leaf.storage_path
        assert Dir.exist?(File.join(@root, "Projects", "desk-lamp"))

        again = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal leaf.node_id, again.node_id
      end

      test "walking an already-existing path costs one query per segment, never the port" do
        assert_already_existing_path_costs_one_query_per_segment
      end
    end
  end
end
