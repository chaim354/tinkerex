require "test_helper"
require "tmpdir"

module Maker
  module Previews
    # THE BOUNDED RUNNER ON ITS OWN (Maker::Previews::Subprocess), with `sh` standing in for a
    # renderer so every case runs on a box with no node and no resvg. Its two users keep their own
    # cases through their own doors (gerber_test.rb, svg_rasterizer_test.rb); these pin what the
    # runner promises whoever calls it.
    class SubprocessTest < ActiveSupport::TestCase
      Stuck = Class.new(StandardError)

      def capture(*cmd, timeout: 5)
        Maker::Previews::Subprocess.capture(*cmd, timeout:, error: Stuck, name: "widget")
      end

      # THE TWO STREAMS COME BACK APART. A renderer's stderr carries its reasons and its stdout the
      # picture; merged, one is spliced into the other.
      test "a program that finishes answers its stdout, its stderr and its status, each on its own" do
        out, err, status = capture("sh", "-c", "echo picture; echo reason >&2; exit 3")

        assert_equal "picture\n", out
        assert_equal "reason\n", err
        assert_equal 3, status.exitstatus
      end

      # THE ELAPSED TIME IS ASSERTED FIRST, as in gerber_test.rb: a `join` with no limit raises
      # nothing here at all, and one that waited the full twenty seconds must not read as bounded.
      #
      # THE SLEEP IS NOT `exec`ed, on purpose: sh may leave `sleep` as a CHILD, which is the
      # grandchild case the runner kills the process GROUP for. Killing only the direct child leaves
      # that orphan holding the stdout pipe, and the reader thread then blocks for the whole sleep.
      test "a program that outlives the limit is killed with its children, and the caller's error is raised" do
        Dir.mktmpdir do |dir|
          script = File.join(dir, "stuck")
          File.write(script, "#!/bin/sh\nsleep 20\n")
          File.chmod(0o755, script)

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          error = assert_raises(Stuck) { capture(script, timeout: 1) }
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          assert_operator elapsed, :<, 5,
                          "the run took #{elapsed.round(1)}s against a 1s limit: it was not bounded"
          assert_equal "widget timed out after 1s", error.message
        end
      end

      # FAR PAST A PIPE BUFFER (64 KiB), because a board's SVG is. A runner that waits for the
      # program and only then reads deadlocks here: the child blocks writing while the parent blocks
      # waiting, and the limit then fires on a program that was working.
      test "output far larger than a pipe buffer is read whole, not deadlocked on" do
        out, _err, status = capture("sh", "-c", "head -c 2000000 /dev/zero | tr '\\0' 'x'", timeout: 20)

        assert_predicate status, :success?
        assert_equal 2_000_000, out.bytesize
      end

      test "a program that cannot be started raises the system's own error, for the caller to map" do
        assert_raises(Errno::ENOENT) { capture("/nonexistent/renderer-binary") }
      end
    end
  end
end
