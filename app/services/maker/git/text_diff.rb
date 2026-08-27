require "diff/lcs"

module Maker
  module Git
    # TWO VERSIONS OF ONE TEXT FILE, AS LINES.
    #
    # THIS IS HALF OF A COMPARE SURFACE, NOT THE WHOLE OF ONE, AND THE OTHER HALF IS WHY IT EXISTS.
    # A text diff of a STEP file is worthless -- the bytes are a CAD kernel's serialisation and a
    # line-oriented diff of them says nothing a maker can act on -- so the pointer half of the
    # library gets two RENDERS side by side instead. WHICH HALF A FILE GETS IS
    # `Maker::Git::Tracking.mode_for`, ASKED BY THE CALLER, AND MUST NOT BE RE-DERIVED HERE from
    # whether the bytes happen to look like text. That is the same decision the commit path already
    # made about this file (content in the repo vs a pointer to content), so asking it twice with
    # two different rules is how the two surfaces come to disagree about one file. This class
    # therefore has no opinion about file NAMES at all and is handed two strings.
    #
    # A REFUSAL IS AN ANSWER, AND A TRUNCATION IS NOT. Diffing two 10 MB files inside a request is a
    # real cost (measured below), so both sides are capped -- but a diff cut off at row 2,000 and
    # rendered without saying so is the "well-formed lie" shape this repo keeps recording (§14b's
    # paginated listing that reads exactly like the user deleting 82% of their library). So the cap
    # produces a REFUSAL carrying both sides' measured size, and nothing partial is ever returned:
    # `rows` is empty whenever `refused` is set.
    #
    # WHERE THE NUMBERS COME FROM. `Diff::LCS.sdiff` is near-free on ordinary edits -- 100,000 lines
    # of scattered changes in 0.105 s -- and QUADRATIC on ambiguity, which is the shape that
    # actually threatens a Puma thread and the shape real files reach: a g-code file, a CSV, or any
    # format whose lines are drawn from a small alphabet. Measured on this box, two files of
    # randomly shuffled lines over an 8-symbol alphabet:
    #
    #     2,000 lines   0.18 s          10,000 lines    5.41 s
    #     5,000 lines   1.28 s          20,000 lines   23.88 s
    #
    # MAX_LINES is set at the first of those. §14e's head-of-line argument binds here exactly as it
    # does for `ADDON_SERVICE_MAX_TIMEOUT` and `database.yml`'s `timeout:` -- production runs 16
    # threads on one Puma worker, so a page that can spend seconds is a page that can occupy them.
    #
    # BOTH CAPS ARE NEEDED AND NEITHER SUBSTITUTES FOR THE OTHER: MAX_LINES bounds the quadratic
    # term above, and MAX_BYTES bounds the shape MAX_LINES cannot see -- a minified JSON or a
    # single-line SVG is ONE line and can be 10 MB, which passes a line cap and then costs that
    # much memory per side to hold, escape and render.
    class TextDiff
      # Per SIDE, not per pair: the pair's cost is driven by the larger of the two.
      MAX_LINES = 2_000
      MAX_BYTES = 256 * 1024

      # Unchanged lines kept around each run of changes. ELISION IS NOT TRUNCATION, and the
      # difference is that an elided run is COUNTED and said out loud -- `skipped` is what the view
      # renders as "N unchanged lines". Dropping the count is what would turn this into the lie the
      # class header refuses.
      CONTEXT_LINES = 3

      # WHAT MAKES A DIFF UNRENDERABLE, each a different fact and none of them an error:
      #
      #   :too_large  one side is past a cap above. Recoverable by the user (open the file), and the
      #               view names the measured size against the limit rather than saying "too big".
      #   :binary     the bytes are not text this page can show -- invalid UTF-8, or a NUL byte,
      #               which is git's own binary test. A file can reach here while being `:content`
      #               tracked: `Maker::Git::Tracking` decides by NAME, so a `.txt` holding UTF-16
      #               or a `README` that is secretly a zip both land here. Rendering it anyway is
      #               not an option -- ERB raises on invalid encoding, at render time, on a page
      #               that had already done all its work.
      #   :missing    the blob is not in one of the two commits. The caller's rescue; see
      #               `.missing`.
      REFUSALS = %i[too_large binary missing].freeze

      # ONE ROW OF THE RENDERED DIFF. `kind` is the CSS state and the four are deliberately
      # distinct: a view that could not tell `added` from `removed` would render a deletion as an
      # insertion, which is worse than rendering nothing.
      #
      # `old_number`/`new_number` ARE 1-BASED AND EITHER MAY BE NIL -- an added line has no line
      # number on the left and a removed one has none on the right. A view must print the blank
      # rather than substituting the other side's number.
      Row = Data.define(:kind, :old_number, :new_number, :text, :skipped)

      Size = Data.define(:lines, :bytes)

      Result = Data.define(:rows, :refused, :before_size, :after_size) do
        def refused? = !refused.nil?
        def added = rows.count { |r| r.kind == :added }
        def removed = rows.count { |r| r.kind == :removed }
        # NOT `rows.empty?`. An unchanged file still yields context rows, and an EMPTY file yields
        # none at all -- so "no rows" and "no changes" are two different facts and only one of them
        # is worth a sentence.
        def identical? = !refused? && added.zero? && removed.zero?
      end

      # THE BLOB IS NOT IN ONE OF THE COMMITS. Reachable only if the repository moved under the
      # request -- the caller picks both commits out of the version list it just read -- but it must
      # not fall through to `Projects::HistoryController`'s outer `rescue FileLayer::NotFound`,
      # which renders "this project's library folder is missing". That sentence would be false, and
      # §14a's rule is that a recoverable-looking state and a permanent one never render alike.
      def self.missing = Result.new(rows: [], refused: :missing, before_size: nil, after_size: nil)

      def self.between(before:, after:) = new(before, after).call

      # HELD AS BYTES, TAGGED UTF-8 ONLY ONCE THE CHECKS HAVE PASSED. This is not tidiness: on a
      # UTF-8-TAGGED string carrying an invalid sequence, `String#count` RAISES
      # `ArgumentError: invalid byte sequence in UTF-8` -- so measuring before re-tagging turns the
      # binary case from a refusal into a 500, and it does so on the one input the refusal exists
      # for. Found by driving the case rather than by reading the method. Every operation below
      # `call`'s two guards therefore runs on bytes, where none of them can raise.
      def initialize(before, after)
        @before = before.to_s.b
        @after = after.to_s.b
      end

      def call
        before_size = measure(@before)
        after_size = measure(@after)
        return refuse(:binary, before_size, after_size) unless text?(@before) && text?(@after)
        return refuse(:too_large, before_size, after_size) if over_cap?(before_size) || over_cap?(after_size)

        Result.new(rows: elide(compare), refused: nil, before_size:, after_size:)
      end

      private

      def refuse(reason, before_size, after_size)
        Result.new(rows: [], refused: reason, before_size:, after_size:)
      end

      # `count("\n")` RATHER THAN `lines.size`, because this runs BEFORE the caps and splitting a
      # 10 MB string to find out it is too big is the cost the cap exists to avoid. The trailing
      # `+ 1` is the last line where the file does not end in a newline; an empty string is 0 lines.
      def measure(str)
        newlines = str.count("\n")
        Size.new(lines: str.empty? ? 0 : newlines + (str.end_with?("\n") ? 0 : 1), bytes: str.bytesize)
      end

      def over_cap?(size) = size.lines > MAX_LINES || size.bytes > MAX_BYTES

      # GIT'S OWN TEST, PLUS THE ONE RUBY FORCES ON US. A NUL byte means binary by convention; an
      # invalid UTF-8 sequence means unrenderable in fact -- and `valid_encoding?` asks about the
      # bytes under the TAG, so it has to be asked of a UTF-8-tagged copy. Asking it of what rugged
      # hands back answers TRUE for anything at all, because every byte string is valid ASCII-8BIT
      # (§14b records the same trap waving a `\xFF` S3 key straight into `storage_path`).
      def text?(str) = !str.include?("\0".b) && utf8(str).valid_encoding?

      def utf8(str) = str.dup.force_encoding(Encoding::UTF_8)

      # `sdiff` PAIRS a change into one `!` record; this splits it back into a removed row and an
      # added row, in that order, so a run of edits reads the way a unified diff does. Keeping it
      # paired would need a third "changed" kind that no styling could show more clearly than the
      # two it already has.
      def compare
        before = utf8(@before).lines
        after = utf8(@after).lines

        ::Diff::LCS.sdiff(before, after).flat_map do |change|
          case change.action
          when "=" then [ row(:context, change) ]
          when "!" then [ removed_row(change), added_row(change) ]
          when "-" then [ removed_row(change) ]
          when "+" then [ added_row(change) ]
          else [] # sdiff emits no other action; an unknown one is dropped rather than mis-rendered.
          end
        end
      end

      def row(kind, change)
        Row.new(kind:, old_number: change.old_position + 1, new_number: change.new_position + 1,
                text: change.old_element.to_s.chomp, skipped: nil)
      end

      def removed_row(change)
        Row.new(kind: :removed, old_number: change.old_position + 1, new_number: nil,
                text: change.old_element.to_s.chomp, skipped: nil)
      end

      def added_row(change)
        Row.new(kind: :added, old_number: nil, new_number: change.new_position + 1,
                text: change.new_element.to_s.chomp, skipped: nil)
      end

      # COLLAPSE A LONG RUN OF UNCHANGED LINES INTO ONE COUNTED ROW. A 2,000-line file with a
      # one-line edit is otherwise 2,000 rows of DOM to find one of them in.
      #
      # THE COUNT IS THE WHOLE POINT: a `:gap` row carries `skipped` and nothing else, so the view
      # can say how many lines it is not showing. A gap rendered as a bare ellipsis is the
      # truncation this class refuses one paragraph up, wearing different clothes.
      def elide(rows)
        keep = Array.new(rows.size, false)
        rows.each_with_index do |r, i|
          next if r.kind == :context

          ((i - CONTEXT_LINES)..(i + CONTEXT_LINES)).each { |j| keep[j] = true if j >= 0 && j < rows.size }
        end

        out = []
        run = 0
        rows.each_with_index do |r, i|
          if keep[i]
            out << gap(run) if run.positive?
            run = 0
            out << r
          else
            run += 1
          end
        end
        out << gap(run) if run.positive?
        out
      end

      def gap(count) = Row.new(kind: :gap, old_number: nil, new_number: nil, text: nil, skipped: count)
    end
  end
end
