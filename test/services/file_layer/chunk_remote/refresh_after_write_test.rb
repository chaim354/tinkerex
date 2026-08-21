# frozen_string_literal: true

require "test_helper"

module FileLayer
  class ChunkRemote
    # THE ONE THING THE LOOPBACK MUTATION SUITE STRUCTURALLY CANNOT SEE.
    #
    # `mutation_contract_test.rb` drives the REAL engine controllers, which is right for semantics --
    # collision refusal, subtree cascade, tombstone-not-destroy are the server's rules and a fake
    # would only confirm this adapter's guesses about them. But server and client share ONE DATABASE
    # there, so `Sync::Mutation.apply` writes the very `nodes` row the adapter then reads. Deleting
    # `refresh!` outright left all nine of those tests GREEN -- verified, not supposed.
    #
    # In a real deployment those are two databases and the pull is the only thing that carries a
    # write back. So this suite gives the server state the client does NOT have: the transport
    # accepts the mutation and reports it only through /v1/changes, exactly as a remote server would.
    class RefreshAfterWriteTest < ActiveSupport::TestCase
      # Records what was asked, and serves a changelog the local database knows nothing about.
      class RemoteOnlyTransport
        attr_reader :calls

        def initialize = (@calls = []; @changes = []; @head = 0)

        # What the "server" will reveal on the next pull -- never written locally by this test.
        def will_report(node_id:, name:, kind: "dir", deleted: false)
          @head += 1
          @changes << { "seq" => @head, "op" => "mkdir", "node_id" => node_id,
                        "node" => { "node_id" => node_id, "parent_node_id" => nil, "name" => name,
                                    "kind" => kind, "deleted" => deleted, "mode" => nil, "mtime" => 1 } }
        end

        def get(path, params = {})
          @calls << [ :get, path ]
          return { "nodes" => [], "head_seq" => @head, "next_after_id" => 0 } if path == "/v1/tree"

          since = params[:since].to_i
          { "changes" => @changes.select { |c| c["seq"] > since },
            "head_seq" => @head, "oldest_seq" => 1 }
        end

        # MIRRORS THE REAL ENDPOINT: `mkdir` is `params.require(:node_id)`, so the server takes the
        # id the CLIENT minted and reports it back through the changelog. An earlier version of this
        # fake invented its own id, which is not a thing the server can do -- and the test failed for
        # that reason rather than for the one it exists to check.
        def post(path, body = {})
          @calls << [ :post, path ]
          will_report(node_id: body[:node_id], name: body[:name], kind: "dir") if path == "/v1/nodes"
          { "seq" => @head }
        end
        def delete(path) = (@calls << [ :delete, path ]; { "seq" => @head })
      end

      setup do
        @user = User.create!(email: "refresh@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
        @transport = RemoteOnlyTransport.new
        @adapter = ChunkRemote.new(transport: @transport)
      end

      test "mkdir returns state the server reported, which only a pull could have supplied" do
        # The local database has NO row for this node. If mkdir does not pull, its own `stat` cannot
        # find one and the verb raises instead of answering -- which is what a missing refresh
        # actually costs a caller.
        assert_equal 0, @user.nodes.count, "the local database must start with nothing"

        info = nil
        assert_nothing_raised { info = @adapter.mkdir(@user, parent_node_id: nil, name: "Made Remotely") }
        assert_equal "Made Remotely", info.name
        assert_equal "dir", info.kind

        # The row exists locally ONLY because the pull applied the server's changelog. Nothing in
        # this test wrote it, and mkdir itself writes no rows.
        assert_equal 1, @user.nodes.count
        assert_equal info.node_id, @user.nodes.first.node_id
      end

      test "every mutation pulls, so the mirror never lags a write it just made" do
        @adapter.mkdir(@user, parent_node_id: nil, name: "thing")

        pulls = @transport.calls.count { |verb, path| verb == :get && path == "/v1/changes" }
        assert_operator pulls, :>=, 1, "a mutation that never pulls leaves the mirror behind the server"
      end

      test "delete pulls too, so a tombstone the server made becomes visible locally" do
        @user.nodes.create!(node_id: "doomed", name: "bye.stl", kind: "file")
        @transport.will_report(node_id: "doomed", name: "bye.stl", kind: "file", deleted: true)

        @adapter.delete(@user, node_id: "doomed")
        assert @user.nodes.find_by(node_id: "doomed").deleted,
               "the local row still reads live after the server tombstoned it"
      end
    end
  end
end
