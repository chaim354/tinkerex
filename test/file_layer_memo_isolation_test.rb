# frozen_string_literal: true

require "test_helper"

# THE HARNESS OWNS FileLayer.current's PER-TEST LIFETIME. The memo is process-global and outlives the
# per-test rollback, and config/initializers/content_security_policy.rb reads it on every response, so
# an adapter one test installed is what the next test's first request in this forked worker runs
# against. Until this landed, test_helper reset it only behind two flags that two helpers set; a direct
# `FileLayer.current = …` set neither, so its reset was the CALLER's job at ~90 sites in 45 files, and
# a missed one failed in a different test chosen by random order (the record has two such incidents,
# test_helper.rb names both). Now the shared teardown resets unconditionally, and this is the guard
# for the one case the flags never covered: a raw assignment is gone after its test tears down.
#
# Same Probe pattern as fresh_share_library_cleanup_test.rb, for the same reason: no test can observe
# its own teardown, so a throwaway TestCase is driven through minitest's `run` — which is what fires
# the :after callbacks test_helper registers — and inspected from outside.
class FileLayerMemoIsolationTest < ActiveSupport::TestCase
  # NO `test_`-PREFIXED METHOD, so minitest collects nothing from this class; the method is invoked by
  # name. A full ActiveSupport::TestCase because the teardown under test is registered there.
  class Probe < ActiveSupport::TestCase
    # A ChunkRemote adapter: a few ivar assignments and no I/O, and nothing in this run's ENV builds
    # one on its own — so finding it in the memo afterwards can only mean the assignment leaked.
    def assign_directly
      FileLayer.current = FileLayer::ChunkRemote.new
      assert_instance_of FileLayer::ChunkRemote, FileLayer.current, "precondition: the assignment took"
    end
  end

  test "an adapter a test assigns to FileLayer.current directly is gone once that test tears down" do
    prior = FileLayer.instance_variable_get(:@current)
    result = Probe.new(:assign_directly).run
    assert_empty result.failures, "the probe itself failed: #{result.failures.inspect}"

    assert_nil FileLayer.instance_variable_get(:@current),
               "a direct `FileLayer.current =` outlived its test — the shared teardown must reset the " \
               "memo unconditionally, not only behind a helper's flag"
  ensure
    FileLayer.instance_variable_set(:@current, prior)
  end
end
