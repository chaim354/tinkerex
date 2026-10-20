# CLAUDE.md §15's RULE AS CODE: the three backend legs of bin/ci (`test` = share, `test-s3`,
# `test-chunk-remote`) must report IDENTICAL RUN counts, and this is what compares them. config/ci.rb
# tees each leg's output to tmp/ci/<gate>.log and, once every selected gate has run, asks `verdict`
# about the legs that ran. Until this landed nothing compared them: bin/ci printed three numbers and
# a person was supposed to read them out of scrollback, and the close-out command file asked for
# identical ASSERTION counts, which never hold.
#
# PLAIN RUBY ON PURPOSE. bin/ci loads this with `require_relative` and nothing of Rails (it requires
# only config/boot), while the test process autoloads it as Ci::LegRuns — the name Zeitwerk derives
# from lib/ci/leg_runs.rb, which CI's eager load (config.eager_load = ENV["CI"].present?) checks on
# every run. A top-level `LegRuns` here would be a Zeitwerk::NameError at that eager load.
#
# RUNS ONLY. Assertions and skips differ between legs BY STRUCTURE — capability-gated tests skip on
# share and s3 and run to completion on chunk_remote (+7 / +~160 assertions, 32 / 33 / 8 skips on
# every full run) — and tinkerex#131's ±2 assertion flap varies between runs of the SAME leg. The run
# count is the one number that depends on the code revision alone, so it is compared exactly.
#
# A MISSING SUMMARY IS A DISAGREEMENT, NEVER A ZERO. A leg that died before Minitest reported (or
# never started tee-ing) has no `N runs, …` line; read as 0 it would agree with any other leg that
# died the same way, and the comparison would be green over two crashed suites. config/ci.rb removes
# the previous run's logs up front for the same reason: a stale log reads as a summary from THIS run.
module Ci
  module LegRuns
    # Minitest's own summary line, anchored at a line start. A log can hold TWO of these — the
    # chunk_remote gate runs the journey file and then the full suite — and the LAST is the one §15
    # compares, which is why `parse` never takes the first match.
    SUMMARY = /^(\d+) runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips\b/

    class Missing < StandardError; end

    Verdict = Struct.new(:agree, :table) do
      alias_method :agree?, :agree
    end

    # The run count on the LAST summary line of `text`. Raises Missing when there is none. Scans
    # BYTES, not characters: a leg's log holds the suite's own UTF-8 (✅, →, …), and bin/ci runs under
    # whatever locale the shell gives it -- US-ASCII on a bare runner or in a scripted shell -- so a
    # string tagged with that locale and holding those bytes makes String#scan raise `invalid byte
    # sequence` in place of a verdict. The first end-to-end run of this comparison died exactly there;
    # the unit test drives a child process under LC_ALL=C to keep it dead.
    def self.parse(text)
      runs = text.b.scan(SUMMARY).flatten
      raise Missing, "no `N runs, M assertions, …` summary line" if runs.empty?

      Integer(runs.last)
    end

    # `parse` over a leg's log, naming the path in either failure: never written, or no summary.
    def self.read(path)
      raise Missing, "#{path} does not exist (the leg died before its output was captured)" unless File.file?(path)

      begin
        parse(File.binread(path))
      rescue Missing => e
        raise Missing, "#{path}: #{e.message}"
      end
    end

    # The verdict on the legs that ran. `logs` is { gate => log path }. Agreement needs EVERY leg to
    # have a summary AND every count to be equal; the table carries one line per leg either way, so
    # a failure prints the numbers rather than a bare "disagree".
    def self.verdict(logs)
      counts = logs.to_h do |gate, path|
        count = begin
          read(path)
        rescue Missing => e
          e
        end
        [ gate, count ]
      end
      width = counts.keys.map(&:length).max.to_i
      table = counts.map do |gate, count|
        detail = count.is_a?(Missing) ? "no summary — #{count.message}" : "#{count} runs"
        "#{gate.ljust(width)}  #{detail}"
      end.join("\n")
      numbers = counts.values.reject { |count| count.is_a?(Missing) }

      Verdict.new(numbers.size == counts.size && numbers.uniq.size == 1, table)
    end
  end
end
