# frozen_string_literal: true

require "test_helper"

# GUARDS THE ONE THING `use_fresh_share_library!` CANNOT ASSERT ABOUT ITSELF: that the tmpdir it
# mints, and the Share adapter it installs, are both gone once the test that asked for them has
# torn down. No test can observe its own teardown, so this drives a throwaway TestCase through
# minitest's `run` — which is what fires the :after callbacks test_helper registers — and then looks
# at the result from outside.
#
# NOT AN EXTERNAL `ls /tmp` COUNT, deliberately. The leak was FOUND by counting directories on the
# build box (2,817 stale `test-library*`, eleven more per full suite run, because the helper left
# cleanup to its 36 callers and one of them — rescan_test.rb — reassigns the very `@root` its own
# teardown reads). But a count is not a gate: it is ambient, it is not reproducible on a fresh
# machine, and CLAUDE.md §15's CI rule ("a gate that makes a tmpdir must clean it up") needs
# something that can go RED. This asks the narrowest true thing instead — one helper call, one
# directory, gone — which is exactly what the fix promises and all it promises.
class FreshShareLibraryCleanupTest < ActiveSupport::TestCase
  # NO `test_`-PREFIXED METHOD, so minitest collects nothing from this class and it costs no run of
  # its own; the methods below are invoked by name. It is a full ActiveSupport::TestCase rather than
  # a bare object because the callbacks under test are registered on ActiveSupport::TestCase — a
  # stand-in that did not inherit them would pass while asserting nothing.
  class Probe < ActiveSupport::TestCase
    class << self
      attr_accessor :root, :decoy
    end

    # The `assert` is a precondition, not the claim — this file's claim is about what is true AFTER
    # teardown. It also keeps Rails' "test is missing assertions" warning off the run, which would
    # otherwise print once per probe invocation and read as a defect in this file.
    def mint
      self.class.root = use_fresh_share_library!
      assert self.class.root.exist?, "precondition: the helper must mint a directory that exists"
    end

    # THE SHAPE THAT CAUSED THE LEAK, reproduced on purpose. rescan_test.rb calls the helper in
    # setup and then REASSIGNS `@root` to a second, hand-rolled tmpdir inside the test, so its own
    # (correct-looking) teardown removes the second directory and drops the first.
    def mint_then_reassign_root
      mint
      self.class.decoy = Pathname.new(Dir.mktmpdir("test-library-decoy"))
      @root = self.class.decoy
    end
  end

  def run_probe(method)
    Probe.root = Probe.decoy = nil
    result = Probe.new(method).run
    assert_empty result.failures, "the probe itself failed: #{result.failures.inspect}"
    assert_not_nil Probe.root, "precondition: the probe must actually have called the helper"
    Probe.root
  end

  test "the tmpdir use_fresh_share_library! mints is removed when the test tears down" do
    root = run_probe(:mint)

    assert_not root.exist?,
               "use_fresh_share_library! leaked #{root} — the helper must remove what it mints"
  end

  # THE ONE THAT PINS THE IVAR CHOICE, and it is not a duplicate of the test above: a fix that
  # recorded the helper's directory in `@root` passes that one and leaks here, which is precisely
  # the bug that shipped. Mutation-checked in exactly that direction.
  test "it still removes its own tmpdir when the caller reassigns @root, as rescan_test.rb does" do
    root = run_probe(:mint_then_reassign_root)

    assert_not root.exist?,
               "use_fresh_share_library! leaked #{root} once @root was reassigned — the helper " \
               "must track what IT minted, not an ivar its callers are free to overwrite"
  ensure
    # The decoy is the caller's directory, not the helper's, so nothing in test_helper owns it.
    FileUtils.remove_entry(Probe.decoy) if Probe.decoy&.exist?
  end

  # THE OTHER HALF, AND NOT DECORATION: removing the directory while leaving a Share adapter
  # pointing AT it in FileLayer.current trades a disk leak for a worse one — the next test in this
  # forked worker inherits an adapter whose root no longer exists, and fails somewhere that names
  # neither this helper nor the test that leaked it. `use_fresh_share_library!` assigns
  # FileLayer.current directly and so sets no @file_layer_backend_pinned, which is why the pin
  # branch of test_helper's teardown does not cover it and this branch has its own reset.
  test "the Share adapter it installed is reset when the test tears down" do
    prior = FileLayer.instance_variable_get(:@current)
    run_probe(:mint)

    assert_nil FileLayer.instance_variable_get(:@current),
               "use_fresh_share_library! left its Share adapter memoized in FileLayer.current"
  ensure
    FileLayer.instance_variable_set(:@current, prior)
  end
end
