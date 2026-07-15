require "test_helper"

module FileLayer
  class FactoryTest < ActiveSupport::TestCase
    setup { FileLayer.reset! }
    teardown { FileLayer.reset! }

    test "defaults to the chunk adapter" do
      assert_instance_of FileLayer::Chunk, FileLayer.current
    end

    test "LIBRARY_BACKEND=chunk selects the chunk adapter" do
      with_backend("chunk") { assert_instance_of FileLayer::Chunk, FileLayer.current }
    end

    test "an unknown backend refuses to build rather than silently defaulting" do
      with_backend("nope") do
        assert_raises(ArgumentError) { FileLayer.current }
      end
    end

    # share/s3 are Phases 2-3. Until then an operator setting them must get a loud error,
    # never a silent fallback to chunk mode (which would read the WRONG library).
    test "share and s3 are not yet implemented and say so" do
      %w[share s3].each do |backend|
        with_backend(backend) do
          assert_raises(NotImplementedError) { FileLayer.current }
        end
      end
    end

    test "current is memoized and reset! clears it" do
      first = FileLayer.current
      assert_same first, FileLayer.current
      FileLayer.reset!
      assert_not_same first, FileLayer.current
    end

    def with_backend(value)
      prior = ENV["LIBRARY_BACKEND"]
      ENV["LIBRARY_BACKEND"] = value
      FileLayer.reset!
      yield
    ensure
      ENV["LIBRARY_BACKEND"] = prior
      FileLayer.reset!
    end
  end
end
