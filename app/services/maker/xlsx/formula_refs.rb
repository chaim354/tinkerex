require "strscan"

module Maker
  module Xlsx
    # REWRITES THE REFERENCES INSIDE A STORED FORMULA, the way Excel does when rows move or when a
    # shared formula's dependent cell needs its own text. A workbook stores formulas as A1 text in
    # `<f>` elements with no leading `=`, so inserting or deleting rows in one sheet means rewriting
    # every formula, on every sheet, that points into it.
    #
    # ONLY WHAT IS RECOGNISED AS A REFERENCE CAN CHANGE. String literals, numbers, error literals,
    # function and defined names, operators and whitespace are copied byte for byte, so anything
    # unfamiliar is left alone rather than mangled. That is only safe because the three constructs
    # whose targets cannot be placed from the text alone are REFUSED with `Unsupported`: structured
    # table references and external workbook references (any `[`), and 3-D references across a run
    # of sheets (`Sheet1:Sheet3!A1`) — shifting those needs a table's extent, another workbook, or
    # the sheet order. A defined name that points at the sheet is not visible here at all (its
    # definition lives in workbook.xml); refusing that is the caller's job.
    module FormulaRefs
      class Unsupported < StandardError; end

      MAX_ROW = Xlsx::MAX_ROW
      MAX_COL = Xlsx::MAX_COL # XFD

      # One end of a reference. A whole-row area's ends have no column, a whole-column area's no row.
      Endpoint = Data.define(:col, :col_abs, :col_text, :row, :row_abs)
      # `kind` is :cell, :area (B2:B4), :rows (2:5) or :cols (A:C). `text` is the reference exactly
      # as written, sheet prefix included, so one that does not move is copied back untouched.
      Ref = Data.define(:prefix, :sheet, :kind, :ends, :text)

      NON_ASCII = "\\u0080-\\u{10FFFF}"
      NAME = /[A-Za-z_\\#{NON_ASCII}][A-Za-z0-9_.#{NON_ASCII}]*/
      # A reference must stand alone: letters-and-digits glued to a name character are part of a
      # longer name, `LOG10(` is a function, and `A1!` would be a sheet called A1.
      AFTER_REF = /(?![A-Za-z0-9_.(!#{NON_ASCII}])/
      # The same rule looking backwards, plus a `$` left over from something that did not parse.
      # A digit is on the list, which is what keeps the exponent of `1E5` from being read as cell E5:
      # numbers need no token of their own, because nothing in one can ever be a reference.
      BEFORE_REF = /[A-Za-z0-9_.$#{NON_ASCII}]/

      CELL = '(\$?)([A-Za-z]{1,3})(\$?)(\d+)'
      REFERENCES = {
        area: /#{CELL}:#{CELL}#{AFTER_REF}/,
        cell: /#{CELL}#{AFTER_REF}/,
        cols: /(\$?)([A-Za-z]{1,3}):(\$?)([A-Za-z]{1,3})#{AFTER_REF}/,
        rows: /(\$?)(\d+):(\$?)(\d+)#{AFTER_REF}/
      }.freeze

      STRING_LITERAL = /"(?:[^"]|"")*"/
      ERROR_LITERAL = %r{#(?:NULL!|DIV/0!|VALUE!|REF!|NAME\?|NUM!|N/A|SPILL!|CALC!|GETTING_DATA|FIELD!|BLOCKED!|CONNECT!|BUSY!|UNKNOWN!)}i
      QUOTED_PREFIX = /'((?:[^']|'')*)'!/
      UNQUOTED_PREFIX = /(#{NAME})!/
      UNQUOTED_3D = /#{NAME}:#{NAME}!/

      private_constant :Endpoint, :Ref, :NON_ASCII, :NAME, :AFTER_REF, :BEFORE_REF, :CELL,
                       :REFERENCES, :STRING_LITERAL, :ERROR_LITERAL, :QUOTED_PREFIX,
                       :UNQUOTED_PREFIX, :UNQUOTED_3D

      class << self
        # Rewrites references for a row insert (count > 0: the old row `at` and everything below
        # moves down by `count`) or a row delete (count < 0: rows at..at+|count|-1 are removed and
        # everything below moves up), on worksheet `target_sheet`. An unqualified reference refers
        # to `home_sheet`, the sheet the formula lives on. `$` does not stop a shift — it only
        # matters when a formula is copied, which is `translate`.
        def shift_rows(formula, home_sheet:, target_sheet:, at:, count:)
          raise ArgumentError, "row #{at} is outside the sheet" unless at.between?(1, MAX_ROW)
          if count.negative? && at - count - 1 > MAX_ROW
            raise ArgumentError, "deleting #{-count} rows at #{at} runs past the sheet"
          end

          rewrite(formula) do |ref|
            next if ref.kind == :cols
            # Excel compares sheet names case-insensitively, so `'my sheet'!A1` points at "My Sheet".
            next unless (ref.sheet || home_sheet).casecmp?(target_sheet)

            top, bottom = ref.ends.map(&:row).minmax
            span = count.positive? ? inserted(top, bottom, at, count) : deleted(top, bottom, at, -count)
            next span if span == :ref

            # An area written bottom-first keeps its order; only the numbers move.
            rows = ref.ends.first.row <= ref.ends.last.row ? span : span.reverse
            ref.ends.zip(rows).map { |point, row| point.with(row:) }
          end
        end

        # Moves every RELATIVE row and column part by (rows, cols) and leaves `$` parts where they
        # are: how Excel derives a shared formula's dependent cell from its master. A reference
        # pushed off the sheet becomes #REF!, keeping its sheet prefix.
        def translate(formula, rows:, cols:)
          rewrite(formula) do |ref|
            moved = ref.ends.map { |point| translated(point, rows, cols) }
            moved.include?(nil) ? :ref : moved
          end
        end

        def supported?(formula)
          tokenize(formula)
          true
        rescue Unsupported
          false
        end

        private

        # The block answers nil (leave it), :ref (it no longer points anywhere) or new endpoints.
        def rewrite(formula)
          tokenize(formula).map { |token|
            next token unless token.is_a?(Ref)

            ends = yield(token)
            if ends == :ref then "#{token.prefix}#REF!"
            elsif ends.nil? || ends == token.ends then token.text
            else "#{token.prefix}#{ends.map { |point| point_text(point) }.join(":")}"
            end
          }.join
        end

        def tokenize(formula)
          scanner = StringScanner.new(formula)
          tokens = []
          until scanner.eos?
            previous = tokens.last
            boundary = previous.nil? || !text_of(previous)[-1].match?(BEFORE_REF)
            tokens << next_token(scanner, boundary)
          end
          tokens
        end

        def next_token(scanner, boundary)
          if (literal = scanner.scan(STRING_LITERAL) || scanner.scan(ERROR_LITERAL))
            literal
          elsif scanner.match?(/"/)
            raise Unsupported, "an unterminated string literal"
          elsif scanner.match?(/\[/)
            raise Unsupported, "a structured or external-workbook reference"
          elsif scanner.match?(/'/)
            prefix = scanner.scan(QUOTED_PREFIX) or raise Unsupported, "a quoted name that is not a sheet prefix"
            sheet = scanner[1].gsub("''", "'")
            # None of these can appear in a real sheet name: `:` is a run of sheets, brackets an
            # external workbook (`'[1]Sheet1'!A1`).
            raise Unsupported, "a 3-D or external reference" if sheet.match?(/[:\[\]]/)

            scan_reference(scanner, prefix:, sheet:) || prefix
          elsif scanner.match?(UNQUOTED_3D)
            raise Unsupported, "a 3-D reference across sheets"
          elsif (prefix = scanner.scan(UNQUOTED_PREFIX))
            scan_reference(scanner, prefix:, sheet: scanner[1]) || prefix
          elsif boundary && (ref = scan_reference(scanner))
            ref
          else
            scanner.scan(NAME) || scanner.getch
          end
        end

        def scan_reference(scanner, prefix: nil, sheet: nil)
          REFERENCES.each do |kind, pattern|
            next unless scanner.check(pattern)

            ends = endpoints(kind, scanner)
            # `XFE1` and `A0` look like references but are names (or nonsense) to Excel.
            next unless ends.all? { |point| on_sheet?(point) }

            body = scanner.matched
            scanner.pos += scanner.matched_size
            return Ref.new(prefix:, sheet:, kind:, ends:, text: "#{prefix}#{body}")
          end
          nil
        end

        def endpoints(kind, m)
          case kind
          when :cell then [ endpoint(m[1], m[2], m[3], m[4]) ]
          when :area then [ endpoint(m[1], m[2], m[3], m[4]), endpoint(m[5], m[6], m[7], m[8]) ]
          when :cols then [ endpoint(m[1], m[2], nil, nil), endpoint(m[3], m[4], nil, nil) ]
          when :rows then [ endpoint(nil, nil, m[1], m[2]), endpoint(nil, nil, m[3], m[4]) ]
          end
        end

        def endpoint(col_abs, letters, row_abs, digits)
          Endpoint.new(col: letters && column_number(letters), col_abs: col_abs == "$", col_text: letters,
                       row: digits&.to_i, row_abs: row_abs == "$")
        end

        def on_sheet?(point)
          (point.col.nil? || point.col.between?(1, MAX_COL)) && (point.row.nil? || point.row.between?(1, MAX_ROW))
        end

        # Insert: everything at or below `at` moves down, so an area straddling `at` grows. An area
        # whose bottom is pushed past the last row is clipped to it (a column-long range stays
        # column-long); one whose top is pushed past — a single cell is top == bottom — has nowhere
        # to be.
        def inserted(top, bottom, at, count)
          new_top = top >= at ? top + count : top
          new_bottom = bottom >= at ? bottom + count : bottom
          return :ref if new_top > MAX_ROW

          [ new_top, [ new_bottom, MAX_ROW ].min ]
        end

        # Delete: an area loses the deleted rows it covered and closes up. One wholly inside them —
        # a single cell included — comes out with its top below its bottom: nothing left to point at.
        def deleted(top, bottom, at, count)
          last = at + count - 1
          new_top = if top < at then top
          elsif top > last then top - count
          else at
          end
          new_bottom = if bottom > last then bottom - count
          elsif bottom >= at then at - 1
          else bottom
          end
          new_top > new_bottom ? :ref : [ new_top, new_bottom ]
        end

        def translated(point, rows, cols)
          col = point.col && (point.col_abs ? point.col : point.col + cols)
          row = point.row && (point.row_abs ? point.row : point.row + rows)
          return unless on_sheet?(Endpoint.new(col:, col_abs: false, col_text: nil, row:, row_abs: false))

          point.with(col:, row:, col_text: col == point.col ? point.col_text : column_letters(col))
        end

        def point_text(point)
          col = point.col ? "#{"$" if point.col_abs}#{point.col_text}" : ""
          row = point.row ? "#{"$" if point.row_abs}#{point.row}" : ""
          col + row
        end

        def text_of(token) = token.is_a?(Ref) ? token.text : token

        def column_number(letters)
          letters.upcase.each_char.reduce(0) { |n, char| n * 26 + char.ord - 64 }
        end

        def column_letters(number)
          letters = +""
          while number.positive?
            number, rem = (number - 1).divmod(26)
            letters.prepend((65 + rem).chr)
          end
          letters
        end
      end
    end
  end
end
