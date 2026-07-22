require "test_helper"

module Maker
  module Previews
    class ThumbnailMapTest < ActiveSupport::TestCase
      # A minimal FileLayer stand-in: ThumbnailMap only calls stat_all, so a duck-typed fake lets
      # us drive the token/preview resolution + the degrade path without a real backend. This is
      # the same `FileLayer.current = …` seam the share/s3 web tests use.
      Info = Struct.new(:content_token)

      class FakeLayer
        def initialize(result) = (@result = result)

        def stat_all(_user, node_ids:)
          raise @result if @result.is_a?(StandardError)
          @result
        end
      end

      setup do
        @user = User.create!(email: "tm-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
      end
      teardown { FileLayer.reset! }

      test "returns the ready thumbnail for a node's current content token" do
        node_id = "node-1"
        token = "tok-1"
        FileLayer.current = FakeLayer.new({ node_id => Info.new(token) })
        p = @user.maker_previews.create!(node_id:, version_id: token, kind: "thumbnail", status: "ready")
        assert_equal p, ThumbnailMap.for(@user, [ node_id ]).thumb(node_id)
      end

      test "nil when there is no preview row for the current token" do
        node_id = "node-2"
        FileLayer.current = FakeLayer.new({ node_id => Info.new("tok") })
        assert_nil ThumbnailMap.for(@user, [ node_id ]).thumb(node_id)
      end

      test "degrades to empty (no raise) when the backend is unreachable" do
        node_id = "node-3"
        FileLayer.current = FakeLayer.new(FileLayer::FetchError.new("nas down"))
        map = ThumbnailMap.for(@user, [ node_id ])
        assert_nil map.thumb(node_id)   # no thumbnail, but the call did not raise
      end

      test "empty input never touches the port" do
        FileLayer.current = FakeLayer.new(RuntimeError.new("should not be called"))
        assert_nil ThumbnailMap.for(@user, []).thumb("x")
      end
    end
  end
end
