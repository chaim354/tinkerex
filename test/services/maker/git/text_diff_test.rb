require "test_helper"

module Maker
  module Git
    class TextDiffTest < ActiveSupport::TestCase
      # ADDED AND REMOVED ARE TWO KINDS, NOT ONE "CHANGED" KIND. A surface that could not tell them
      # apart would render a deletion as an insertion.
      test "an edited line yields a removed row and an added row, in that order" do
        result = TextDiff.between(before: "one\ntwo\nthree\n", after: "one\nTWO\nthree\n")

        assert_not result.refused?
        assert_equal %i[context removed added context], result.rows.map(&:kind)
        assert_equal 1, result.added
        assert_equal 1, result.removed
        assert_equal "two", result.rows[1].text
        assert_equal "TWO", result.rows[2].text
      end

      # A LINE NUMBER BELONGS TO THE SIDE THAT HAS THE LINE. An added line has none on the left; a
      # removed one has none on the right. Substituting the other side's number is a plausible
      # "tidy-up" that makes the gutter lie.
      test "line numbers are 1-based and absent on the side that has no line" do
        result = TextDiff.between(before: "keep\ndrop\n", after: "keep\nadd\nadd2\n")

        removed = result.rows.find { |r| r.kind == :removed }
        added = result.rows.select { |r| r.kind == :added }
        assert_equal [ 2, nil ], [ removed.old_number, removed.new_number ]
        assert_equal [ [ nil, 2 ], [ nil, 3 ] ], added.map { |r| [ r.old_number, r.new_number ] }
        assert_equal [ 1, 1 ], result.rows.first.then { |r| [ r.old_number, r.new_number ] }
      end

      test "two identical versions report no changes rather than no rows" do
        result = TextDiff.between(before: "same\n", after: "same\n")

        assert result.identical?
        assert_not result.refused?
      end

      # --- the caps: A REFUSAL IS AN ANSWER, A TRUNCATION IS NOT --------------------------------

      # THE ROWS MUST BE EMPTY, not merely fewer. A partial diff rendered without saying so is the
      # shape this class exists to refuse -- and a test asserting only `refused?` would pass over an
      # implementation that returned the first 2,000 rows AND set the flag.
      test "a version past the line cap is refused whole, with both sides measured" do
        big = ("x\n" * (TextDiff::MAX_LINES + 1))
        result = TextDiff.between(before: "small\n", after: big)

        assert_equal :too_large, result.refused
        assert_empty result.rows
        assert_equal TextDiff::MAX_LINES + 1, result.after_size.lines
        assert_equal 1, result.before_size.lines
      end

      # THE OTHER CAP, AND THE SHAPE THE LINE CAP CANNOT SEE: a minified document is ONE line and
      # can be megabytes. Deleting either cap must fail a test, so this one stays under the line
      # limit deliberately.
      test "a single enormous line is refused on bytes, under the line cap" do
        one_line = "#{'y' * (TextDiff::MAX_BYTES + 1)}\n"
        result = TextDiff.between(before: "small\n", after: one_line)

        assert_equal :too_large, result.refused
        assert_operator result.after_size.lines, :<=, TextDiff::MAX_LINES,
                        "this fixture must be refused on BYTES, or it stops covering that cap"
        assert_operator result.after_size.bytes, :>, TextDiff::MAX_BYTES
      end

      test "a version just inside both caps is diffed" do
        just_inside = "z\n" * TextDiff::MAX_LINES
        result = TextDiff.between(before: just_inside, after: just_inside)

        assert_not result.refused?
      end

      # `Maker::Git::Tracking` DECIDES BY NAME, so a `.txt` holding UTF-16 reaches here as content.
      # ERB raises on invalid encoding at RENDER time, after the page has done all its work.
      test "bytes that are not valid UTF-8 are refused as binary, not diffed" do
        result = TextDiff.between(before: "fine\n", after: "bad \xFF\xFE byte\n")

        assert_equal :binary, result.refused
        assert_empty result.rows
      end

      # Git's own binary test. ASCII-8BIT input is why `valid_encoding?` alone is not enough --
      # every byte string is "valid" under that tag.
      test "a NUL byte is binary even when the bytes are valid UTF-8" do
        result = TextDiff.between(before: "fine\n", after: "has\0nul\n")

        assert_equal :binary, result.refused
      end

      # rugged hands back ASCII-8BIT. Without the re-tag in `text?` this fixture diffs happily and
      # then explodes in the view.
      test "an ASCII-8BIT blob is judged on its bytes, not on its tag" do
        blob = "bad \xFF\xFE byte\n".dup.force_encoding(Encoding::ASCII_8BIT)
        assert blob.valid_encoding?, "the fixture must be 'valid' under its own tag, or this proves nothing"

        assert_equal :binary, TextDiff.between(before: "fine\n", after: blob).refused
      end

      # --- elision: COUNTED, NEVER SILENT -------------------------------------------------------

      test "a long unchanged run collapses into one row that says how many lines it hides" do
        before = (1..50).map { |i| "line #{i}\n" }.join
        after = before.sub("line 25\n", "LINE 25\n")

        result = TextDiff.between(before:, after:)

        gaps = result.rows.select { |r| r.kind == :gap }
        assert_equal 2, gaps.size, "one gap above the change and one below"
        # EVERY ROW IS ACCOUNTED FOR, WHICH IS THE CLAIM WORTH ASSERTING -- a hardcoded 43 would go
        # red for a change of CONTEXT_LINES that lost nothing. The edit is one CHANGED line, which
        # sdiff splits into a removed row and an added row, so the diff is 51 rows over a 50-line
        # file: 49 context rows, of which #{TextDiff::CONTEXT_LINES} each side survive.
        context_rows = 49
        kept_context = result.rows.count { |r| r.kind == :context }
        assert_equal 2 * TextDiff::CONTEXT_LINES, kept_context
        assert_equal context_rows - kept_context, gaps.sum(&:skipped),
                     "an elided line that no gap counts is the silent truncation this class refuses"
        assert result.rows.none? { |r| r.kind == :gap && r.skipped.nil? },
               "a gap with no count is that same truncation, wearing an ellipsis"
      end

      test "context lines around a change are kept" do
        before = (1..50).map { |i| "line #{i}\n" }.join
        result = TextDiff.between(before:, after: before.sub("line 25\n", "LINE 25\n"))

        kept = result.rows.select { |r| r.kind == :context }.map(&:text)
        assert_equal [ "line 22", "line 23", "line 24", "line 26", "line 27", "line 28" ], kept
      end

      # --- the caller's rescue ------------------------------------------------------------------

      # NOT the outer `rescue FileLayer::NotFound`, which renders "this project's library folder is
      # missing" -- a sentence that would be false here.
      test "a missing blob is its own refusal with no measurements to report" do
        result = TextDiff.missing

        assert_equal :missing, result.refused
        assert_empty result.rows
        assert_nil result.before_size
      end

      test "every refusal reason the view switches on is declared" do
        assert_equal TextDiff::REFUSALS.sort, %i[binary missing too_large].sort
      end
    end
  end
end
