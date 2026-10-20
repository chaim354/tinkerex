require "test_helper"
require "tmpdir"

# CLAUDE.md §15's RULE AS CODE. The three backend legs (`test` = share, `test-s3`, `test-chunk-remote`)
# must report IDENTICAL RUN counts, and until this landed nothing compared them: `bin/ci` printed three
# numbers and a person was supposed to read them out of scrollback. `config/ci.rb` now tees each leg's
# output and asks Ci::LegRuns for the verdict once the gates have run. This file pins the two halves
# that can be wrong quietly: WHICH number is compared (runs — assertions and skips differ between legs
# by structure, +7 / +~160 assertions and 32 / 33 / 8 skips on every full run, and tinkerex#131's ±2
# assertion flap varies between runs of the SAME leg) and what a MISSING summary means (a leg that
# died before Minitest reported is a disagreement, never a zero that happens to equal another zero).
class CiLegRunsTest < ActiveSupport::TestCase
  # The last lines of a real leg's log, in the shape Minitest prints them. Equal runs, unequal
  # assertions and skips — the shape every full run has (memory: backend-legs-structural-assertion-deltas).
  SHARE  = "Finished in 53.238453s, 87.4932 runs/s, 449.1866 assertions/s.\n" \
           "4658 runs, 23907 assertions, 0 failures, 0 errors, 32 skips\n\n" \
           "You have skipped tests. Run with --verbose for details.\n".freeze
  S3     = SHARE.sub("23907 assertions", "23914 assertions").sub("32 skips", "33 skips").freeze
  REMOTE = SHARE.sub("23907 assertions", "24082 assertions").sub("32 skips", "8 skips").freeze
  NO_SUMMARY = "Running 4658 tests in parallel using 10 processes\nKilled\n".freeze

  test "parse reads the RUN count off the summary line, not the assertions" do
    assert_equal 4658, Ci::LegRuns.parse(SHARE)
  end

  test "parse takes the LAST summary when one log holds two (the journey file, then the full suite)" do
    journey = "10 runs, 126 assertions, 0 failures, 0 errors, 0 skips\n"

    assert_equal 4658, Ci::LegRuns.parse(journey + REMOTE)
  end

  test "a log with no summary line is an error, never 0" do
    err = assert_raises(Ci::LegRuns::Missing) { Ci::LegRuns.parse(NO_SUMMARY) }

    assert_match(/summary/, err.message)
  end

  test "read names the log that was never written" do
    path = File.join(Dir.tmpdir, "leg-runs-never-written-#{SecureRandom.hex(4)}.log")

    err = assert_raises(Ci::LegRuns::Missing) { Ci::LegRuns.read(path) }
    assert_includes err.message, path
  end

  test "legs with equal runs agree, however much their assertions and skips differ" do
    with_logs("test" => SHARE, "test-s3" => S3, "test-chunk-remote" => REMOTE) do |logs|
      verdict = Ci::LegRuns.verdict(logs)

      assert verdict.agree?, verdict.table
      assert_match(/4658/, verdict.table)
    end
  end

  test "legs with different runs disagree, and the table names each leg's count" do
    with_logs("test" => SHARE, "test-s3" => S3.sub("4658 runs", "12 runs")) do |logs|
      verdict = Ci::LegRuns.verdict(logs)

      assert_not verdict.agree?
      assert_match(/^test\b.*\b4658\b/, verdict.table)
      assert_match(/^test-s3\b.*\b12\b/, verdict.table)
    end
  end

  test "a leg without a summary is a disagreement even when every other leg agrees" do
    with_logs("test" => SHARE, "test-s3" => S3, "test-chunk-remote" => NO_SUMMARY) do |logs|
      verdict = Ci::LegRuns.verdict(logs)

      assert_not verdict.agree?
      assert_match(/^test-chunk-remote\b.*no summary/, verdict.table)
    end
  end

  # THE MUTATION THIS EXISTS FOR: "treat a missing summary as 0". Two legs that both died before
  # reporting would then read 0 == 0 and AGREE — green over two crashed suites.
  test "two legs without a summary do not agree with each other" do
    with_logs("test" => NO_SUMMARY, "test-s3" => NO_SUMMARY) do |logs|
      assert_not Ci::LegRuns.verdict(logs).agree?
    end
  end

  test "a log that does not exist reads as no summary, not as agreement" do
    with_logs("test" => SHARE) do |logs|
      logs["test-s3"] = File.join(File.dirname(logs["test"]), "test-s3.log")   # never written

      verdict = Ci::LegRuns.verdict(logs)

      assert_not verdict.agree?
      assert_match(/^test-s3\b.*no summary/, verdict.table)
    end
  end

# THE FIRST END-TO-END RUN OF THE COMPARISON DIED HERE. bin/ci runs under whatever locale the shell
# gives it -- a bare runner or a scripted shell is US-ASCII -- and a leg's log holds the suite's own
# UTF-8 (✅, →, …), so a File.read tagged with that locale made String#scan raise `invalid byte
# sequence` in place of a verdict. Driven through a real child process under LC_ALL=C, exactly as
# bin/ci loads this file (require only, no Rails), because the strings this file hands `parse` are
# UTF-8 literals and could never reproduce it.
test "read parses a log holding non-ASCII bytes under a US-ASCII locale, as bin/ci on a bare runner does" do
  with_logs("test" => "#{SHARE}✅ Tests: Rails (share backend) passed in 55.71s\n") do |logs|
    out = IO.popen({ "LC_ALL" => "C", "LANG" => "C" },
                   [ RbConfig.ruby, "-r", Rails.root.join("lib/ci/leg_runs").to_s,
                     "-e", "print Ci::LegRuns.read(ARGV[0])", logs["test"] ],
                   err: [ :child, :out ], &:read)

    assert_equal "4658", out, "the child process answered:\n#{out}"
  end
end

  private

  # { gate => log text } -> { gate => path }, in a tmpdir that is gone when the block returns.
  def with_logs(texts)
    Dir.mktmpdir("leg-runs") do |dir|
      logs = texts.to_h do |gate, text|
        path = File.join(dir, "#{gate}.log")
        File.write(path, text)
        [ gate, path ]
      end
      yield logs
    end
  end
end
