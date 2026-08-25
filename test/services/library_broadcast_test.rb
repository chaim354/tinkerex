# frozen_string_literal: true

require "test_helper"

# ARC B GAP (c), AT THE UNIT LEVEL. LibraryBroadcast.batch used to be one branch: engine loaded ->
# coalesce through Sync::LibraryChannel, engine absent -> bare `yield`. That collapsed two different
# "engine absent" shapes into one answer -- share/s3 have no changelog, so `yield` is exactly right
# for them, but chunk_remote's changelog is real, just remote, and a bare `yield` there meant N
# mutations inside one batch cost N changelog pulls. The chunk_remote journey suite measured this
# against a REAL server (test/integration/chunk_remote_journey_test.rb's "a batch of moves costs one
# changelog pull, not one per move": 3 moves, 3 pulls). This file pins the same mechanism without a
# server, so it runs in the ordinary `bin/ci test` gate rather than only under the journey suite's
# own real-server requirement.
#
# `FileLayer::ChunkRemote::ChangelogSync.new` IS COUNTED DIRECTLY, exactly as the journey test counts
# it and for the same reason its own comment gives: this repo is pinned to minitest 6.0.6
# (Gemfile.lock), which has dropped minitest/mock entirely, so `Object#stub` is not available --
# there is no mock gem to reach for here either. A manual define_singleton_method/remove_method pair
# performs the identical interception -- count the call, forward to the real `new` -- and restores
# the original in an `ensure` so the patch cannot leak into a later test in this worker.
class LibraryBroadcastTest < ActiveSupport::TestCase
  # SAVES AND RESTORES EVERY GLOBAL LibraryBroadcast.batch CAN READ: `LIBRARY_BACKEND` and its own
  # `SYNC_ENGINE` override (both feed `LibraryBackend.engine_wanted?`), plus `FileLayer.current`.
  # `SYNC_ENGINE` matters here specifically because the three backend CI legs force it to "1" so the
  # engine stays loaded on share/s3 too (CLAUDE.md §14j) -- without pinning it back to "0" for the
  # duration of a chunk_remote-arm test, that ambient override would make `engine_wanted?` answer
  # true regardless of `LIBRARY_BACKEND` and silently route the call through the WRONG arm on those
  # two legs only, while this test passed on the default leg. Reimplemented here rather than reusing
  # test_helper's `pin_file_layer_backend`, because that helper calls `FileLayer.build`, which for
  # "chunk_remote" demands a real `CHUNK_REMOTE_URL`/`CHUNK_REMOTE_TOKEN` this test has no use for --
  # every adapter below is handed a fake transport instead.
  def with_file_layer_env(library_backend:, sync_engine:, current:)
    prior_backend = ENV["LIBRARY_BACKEND"]
    prior_sync_engine = ENV["SYNC_ENGINE"]
    prior_current = FileLayer.instance_variable_get(:@current)

    ENV["LIBRARY_BACKEND"] = library_backend
    ENV["SYNC_ENGINE"] = sync_engine
    FileLayer.current = current
    yield
  ensure
    prior_backend.nil? ? ENV.delete("LIBRARY_BACKEND") : ENV["LIBRARY_BACKEND"] = prior_backend
    prior_sync_engine.nil? ? ENV.delete("SYNC_ENGINE") : ENV["SYNC_ENGINE"] = prior_sync_engine
    FileLayer.instance_variable_set(:@current, prior_current)
  end

  def with_chunk_remote_current(adapter, &block)
    with_file_layer_env(library_backend: "chunk_remote", sync_engine: "0", current: adapter, &block)
  end

  # Records every POST and answers an always-empty, never-gapped changelog, so ChangelogSync#call
  # takes its cheapest path (no resync, zero entries) and returns without this fake having to
  # simulate a real tree. What this fake is FOR is letting #move succeed with no server at all, so
  # what these tests measure is purely HOW MANY TIMES a pull is triggered, never what a pull does --
  # ChangelogSync has its own test file for that.
  class FakeTransport
    attr_reader :posts

    def initialize = (@posts = [])

    def get(_path, _params = {}) = { "changes" => [], "head_seq" => 0, "oldest_seq" => 0 }
    def post(path, body = {}) = (@posts << [ path, body ]; {})
    def delete(_path) = {}
  end

  def node!(user, node_id, name) = user.nodes.create!(node_id:, name:, kind: "file", mtime: 1).node_id

  # A COUNTER OBJECT, NOT A RETURN VALUE -- deliberately. The "raises mid-batch" test below needs the
  # pull count to survive an exception thrown from INSIDE the block this wraps, and a method whose
  # own return value is that count never reaches its `return`/final-expression line when the block it
  # yielded to raises: the exception unwinds straight past it. A Hash mutated by reference has no such
  # gap -- it holds the right count whether the block finished cleanly or not.
  def track_changelog_pulls(counter)
    original_new = FileLayer::ChunkRemote::ChangelogSync.method(:new)
    FileLayer::ChunkRemote::ChangelogSync.define_singleton_method(:new) do |*a, **k|
      counter[:pulls] += 1
      original_new.call(*a, **k)
    end
    yield
  ensure
    FileLayer::ChunkRemote::ChangelogSync.singleton_class.send(:remove_method, :new)
  end

  def new_user = User.create!(email: "broadcast-#{SecureRandom.hex(6)}@example.com",
                              password: "correct horse battery staple", confirmed_at: Time.current)

  test "on chunk_remote, a batch of moves costs one changelog pull, not one per move" do
    user = new_user
    transport = FakeTransport.new
    adapter = FileLayer::ChunkRemote.new(transport:)
    ids = 3.times.map { |i| node!(user, "n#{i}", "f#{i}.stl") }
    counter = { pulls: 0 }

    with_chunk_remote_current(adapter) do
      track_changelog_pulls(counter) do
        LibraryBroadcast.batch(user) do
          ids.each_with_index do |id, i|
            adapter.move(user, node_id: id, new_parent_node_id: nil, new_name: "moved-#{i}.stl")
          end
        end
      end
    end

    assert_equal 1, counter[:pulls],
                 "a batch of 3 moves pulled the changelog #{counter[:pulls]} times; #batch must " \
                 "defer the refresh so an eager project-intake sweep is not 2 WAN round-trips per " \
                 "file"
    assert_equal 3, transport.posts.count { |path, _| path.match?(%r{\A/v1/nodes/.+/move\z}) },
                 "each move must still reach the server -- only the CHANGELOG PULL is coalesced, " \
                 "never the mutation itself"
  end

  # STEP 2'S OWN TEST: a deferral that only pulls on the happy path is worse than none, because it
  # leaves the mirror stale exactly when a caller is about to look at it. Nothing about #batch may
  # swallow the exception either -- a batch that hides what broke inside it would be a second,
  # worse defect layered on top of the one this arc closes.
  test "on chunk_remote, the deferred pull still runs -- and the exception still propagates -- if " \
       "the batch raises" do
    user = new_user
    adapter = FileLayer::ChunkRemote.new(transport: FakeTransport.new)
    id = node!(user, "n0", "f0.stl")
    boom = Class.new(StandardError)
    counter = { pulls: 0 }

    raised = assert_raises(boom) do
      with_chunk_remote_current(adapter) do
        track_changelog_pulls(counter) do
          LibraryBroadcast.batch(user) do
            adapter.move(user, node_id: id, new_parent_node_id: nil, new_name: "moved.stl")
            raise boom, "something broke mid-sweep"
          end
        end
      end
    end

    assert_equal "something broke mid-sweep", raised.message,
                 "#batch must not swallow or replace the block's own exception"
    assert_equal 1, counter[:pulls],
                 "a batch that raises must still pull once on the way out, in an ensure -- a " \
                 "deferral that only works on the happy path is worse than none, because it fails " \
                 "exactly when the mirror is already odd and a caller is about to read it"
  end

  test "on chunk_remote, a batch with no mutations pulls zero times" do
    # DIRTY, NOT "the batch ran" -- an empty sweep (every file already filed) must not pay for a
    # pull that would come back answering nothing new.
    user = new_user
    adapter = FileLayer::ChunkRemote.new(transport: FakeTransport.new)
    counter = { pulls: 0 }

    with_chunk_remote_current(adapter) do
      track_changelog_pulls(counter) { LibraryBroadcast.batch(user) { 1 + 1 } }
    end

    assert_equal 0, counter[:pulls]
  end

  test "on chunk_remote, batch returns the block's own value" do
    user = new_user
    adapter = FileLayer::ChunkRemote.new(transport: FakeTransport.new)

    result = with_chunk_remote_current(adapter) { LibraryBroadcast.batch(user) { :ok } }
    assert_equal :ok, result
  end

  # Maker::ProjectIntake.for_user wraps a loop over projects in one batch, and each project's own
  # #call wraps its own file_all in another, both for the SAME user -- so the inner one MUST join
  # the outer rather than triggering a pull of its own, or a 50-project sweep would be right back to
  # one pull per project instead of one for the whole run.
  test "on chunk_remote, a batch re-entered by the same user joins the outer one" do
    user = new_user
    adapter = FileLayer::ChunkRemote.new(transport: FakeTransport.new)
    a = node!(user, "na", "a.stl")
    b = node!(user, "nb", "b.stl")
    counter = { pulls: 0 }

    with_chunk_remote_current(adapter) do
      track_changelog_pulls(counter) do
        LibraryBroadcast.batch(user) do
          LibraryBroadcast.batch(user) do
            adapter.move(user, node_id: a, new_parent_node_id: nil, new_name: "moved-a.stl")
          end
          adapter.move(user, node_id: b, new_parent_node_id: nil, new_name: "moved-b.stl")
        end
      end
    end

    assert_equal 1, counter[:pulls]
  end

  # A DIFFERENT USER'S BATCH IS NOT A SHAPE THIS APP PRODUCES TODAY (every entry point is
  # user-scoped), but #batch's own comment claims it is handled honestly rather than silently
  # absorbed into someone else's frame -- so it gets its own pull, and the outer user's frame
  # survives underneath it. Pinned rather than left as an argument: each user's own dirty flag
  # must trigger exactly one pull, for THAT user, and the outer frame must still work correctly
  # once the inner one unwinds.
  test "on chunk_remote, a batch for a different user does not join -- it pulls on its own and " \
       "restores the outer frame" do
    outer_user = new_user
    inner_user = new_user
    adapter = FileLayer::ChunkRemote.new(transport: FakeTransport.new)
    outer_node = node!(outer_user, "no1", "outer.stl")
    inner_node = node!(inner_user, "ni1", "inner.stl")
    outer_node_2 = node!(outer_user, "no2", "outer2.stl")
    counter = { pulls: 0 }

    with_chunk_remote_current(adapter) do
      track_changelog_pulls(counter) do
        LibraryBroadcast.batch(outer_user) do
          adapter.move(outer_user, node_id: outer_node, new_parent_node_id: nil,
                       new_name: "moved-outer.stl")

          # A DIFFERENT user's batch, nested inside the first.
          LibraryBroadcast.batch(inner_user) do
            adapter.move(inner_user, node_id: inner_node, new_parent_node_id: nil,
                         new_name: "moved-inner.stl")
          end

          # Back inside the OUTER frame -- must still defer, not have been clobbered by the
          # inner batch's restore.
          adapter.move(outer_user, node_id: outer_node_2, new_parent_node_id: nil,
                       new_name: "moved-outer2.stl")
        end
      end
    end

    assert_equal 2, counter[:pulls],
                 "one pull for the inner user's own batch, one for the outer's -- not one shared, " \
                 "and not zero because a mismatched user id was mistaken for 'no batch open'"
  end

  # THE COMMENT SPLIT THIS TASK REQUIRED, PINNED AS BEHAVIOUR: share/s3 (no changelog, and not
  # chunk_remote) must still get exactly the bare `yield` this module always gave them. FileLayer.
  # current is a bare Object with no #batch method at all here -- if LibraryBroadcast ever called
  # anything on it for this backend, this test would fail LOUDLY (NoMethodError) rather than
  # silently passing on a coincidence.
  test "off chunk_remote and without the engine, batch is still a bare yield" do
    user = new_user
    ran = false

    result = with_file_layer_env(library_backend: "share", sync_engine: "0", current: Object.new) do
      LibraryBroadcast.batch(user) { ran = true; :share_result }
    end

    assert ran, "the block must still run"
    assert_equal :share_result, result
  end

end
