require "test_helper"

module Web
  # THE STREAM ARM OF FileDelivery#answer_range, ON EVERY LEG (2026-11-20, the video player).
  #
  # chunk_remote is the one real adapter that answers a Stream, and its leg needs a running sync
  # server, so the controller's half of the rule is driven here through the real route with a port
  # that answers nothing but `download` — the seam addons_controller_test.rb's doubles use, and all
  # FilesController#blob asks of the port. Which chunks a slice FETCHES is
  # FileLayer::ChunkRemote::ContractTest's half; this file holds the status, the headers, and that a
  # partial body IS the slice rather than the whole stream with a 206 on it.
  class StreamRangeDeliveryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    DIGITS = ("0123456789" * 10).freeze

    # A Stream shaped the way ChunkRemote#download builds one, over a String. `slices` records every
    # range the controller asked for, so "cut from the slice" can be told from "read the whole
    # stream". `ranged: false` is every Stream built before ranges existed: no size, no slice.
    class RangedPort
      attr_reader :slices

      def initialize(bytes, ranged: true)
        @bytes = bytes
        @ranged = ranged
        @slices = []
      end

      def download(_user, node_id:, disposition:, content_type: nil)
        return FileLayer::Delivery::Stream.new(enum: [ @bytes ].each) unless @ranged

        FileLayer::Delivery::Stream.new(
          enum: [ @bytes ].each, size: @bytes.bytesize,
          slice: ->(range) { @slices << range; [ @bytes.byteslice(range.begin, range.size) ].each }
        )
      end
    end

    setup do
      @user = User.create!(email: "srd-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "clip.mp4", kind: "file",
                                  size: DIGITS.bytesize, mtime: 1)
    end

    teardown { FileLayer.reset! }

    test "one range of a ranged stream is a 206 cut from the slice" do
      FileLayer.current = port = RangedPort.new(DIGITS)
      get blob_file_path(@node.node_id), headers: { "Range" => "bytes=40-59" }

      assert_response :partial_content
      assert_equal "bytes 40-59/100", response.headers["Content-Range"]
      assert_equal "20", response.headers["Content-Length"]
      assert_equal DIGITS[40..59], response.body
      assert_equal [ 40..59 ], port.slices
      assert_equal "video/mp4", response.media_type
      assert_match(/\Ainline/, response.headers["Content-Disposition"])
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    end

    test "a range wholly past the end of a ranged stream is a 416 and asks for no slice" do
      FileLayer.current = port = RangedPort.new(DIGITS)
      get blob_file_path(@node.node_id), headers: { "Range" => "bytes=100-" }

      assert_response :range_not_satisfiable
      assert_equal "bytes */100", response.headers["Content-Range"]
      assert_empty port.slices
    end

    test "with no Range a ranged stream is served whole and offered as ranged" do
      FileLayer.current = port = RangedPort.new(DIGITS)
      get blob_file_path(@node.node_id)

      assert_response :success
      assert_equal DIGITS, response.body
      assert_equal "bytes", response.headers["Accept-Ranges"]
      assert_empty port.slices
    end

    test "a stream that names no size is served whole and claims no ranges" do
      FileLayer.current = RangedPort.new(DIGITS, ranged: false)
      get blob_file_path(@node.node_id), headers: { "Range" => "bytes=0-1" }

      assert_response :success
      assert_equal DIGITS, response.body
      assert_nil response.headers["Accept-Ranges"]
    end
  end
end
