module Maker
  module Xlsx
    # THE TEXT A CACHED NUMBER IS SHOWN AS, AND THE ONE QUESTION A SAVE ASKS OF A FORMAT.
    #
    # An .xlsx stores a number as a number and a date as a number too (days since 1900); only the
    # cell's number format says "this is the 15th of March" or "27.7%". The grid shows what Excel
    # would show for the formats a maker's sheet is made of — dates and times, percentages, fixed
    # decimals with or without thousands separators and a currency symbol — and Excel's "General"
    # for the rest. It is a READING, deliberately partial: conditional sections, colours, fractions
    # and scaling commas fall back to General, which shows the true value rather than a wrong one.
    #
    # `kind` is the half a SAVE reads: a date-formatted cell takes a typed `2026-10-21` as a date,
    # and a Text-formatted (`@`) cell keeps a typed `007` as text (Maker::Xlsx::Edit).
    module CellFormat
      # Excel's built-in number formats a workbook may name by id alone. 14-22 and 45-47 are dates
      # and times; 27-36 and 50-58 are the East Asian date formats; 9/10 percentages; 49 text.
      BUILTIN = {
        1 => "0", 2 => "0.00", 3 => "#,##0", 4 => "#,##0.00", 9 => "0%", 10 => "0.00%",
        11 => "0.00E+00", 14 => "yyyy-mm-dd", 15 => "d-mmm-yy", 16 => "d-mmm", 17 => "mmm-yy",
        18 => "h:mm AM/PM", 19 => "h:mm:ss AM/PM", 20 => "h:mm", 21 => "h:mm:ss",
        22 => "yyyy-mm-dd h:mm", 37 => "#,##0 ;(#,##0)", 38 => "#,##0 ;[Red](#,##0)",
        39 => "#,##0.00;(#,##0.00)", 40 => "#,##0.00;[Red](#,##0.00)", 45 => "mm:ss",
        46 => "[h]:mm:ss", 47 => "mm:ss.0", 48 => "##0.0E+0", 49 => "@"
      }.freeze
      EAST_ASIAN_DATE_IDS = ((27..36).to_a + (50..58).to_a).freeze

      CURRENCY = /[$€£¥]/

      module_function

      # :general, :number, :percent, :date, :time, :datetime, :text
      def kind(code)
        return :general if code.nil? || code.strip.empty? || code.strip.casecmp?("General")

        section = strip_literals(code.split(";").first.to_s)
        return :text if section.strip == "@"

        has_date = section.match?(/[yd]/i) || section.match?(/m/i) && !section.match?(/[hs]/i)
        has_time = section.match?(/[hs]/i) || section.match?(/AM\/PM|A\/P/i)
        return :datetime if has_date && has_time && section.match?(/[yd]/i)
        return :time if has_time
        return :date if has_date
        return :percent if section.include?("%")

        section.match?(/[0#?]/) ? :number : :general
      end

      def code_for(numfmt_id, custom)
        custom[numfmt_id] || BUILTIN[numfmt_id] || (EAST_ASIAN_DATE_IDS.include?(numfmt_id) ? "yyyy-mm-dd" : nil)
      end

      # `raw` is the `<v>` text of a number cell. Anything that does not parse as a number is shown
      # as it is (a corrupt value is still the file's value).
      def display(raw, code, date1904: false)
        f = Float(raw, exception: false)
        return raw.to_s if f.nil? || !f.finite?

        case kind(code)
        when :date then serial_time(f, date1904)&.strftime("%Y-%m-%d") || general(f)
        when :datetime then serial_time(f, date1904)&.strftime("%Y-%m-%d %H:%M") || general(f)
        when :time then time_of_day(f, code)
        when :percent then decorate(f * 100, code, suffix: "%")
        when :number then decorate(f, code)
        else general(f)
        end
      end

      # Excel's "General": an integer as an integer, otherwise at most ten significant digits with
      # the trailing zeros gone, and scientific notation only for the very large and very small.
      def general(f)
        return "0" if f.zero?
        return f.to_i.to_s if f == f.round && f.abs < 1e15

        mag = Math.log10(f.abs).floor
        return format("%.5E", f) if mag >= 11 || mag < -9

        digits = [ 9 - mag, 0 ].max
        format("%.#{digits}f", f.round(digits)).sub(/\.?0+\z/, "")
      end

      # The 1900 date system counts 1900-02-29, which never happened (Lotus's bug, kept for
      # compatibility), so serials from 61 on are one day ahead of a plain count from 1899-12-31.
      # Negative serials and the fictitious day show as General rather than as a wrong date.
      def serial_time(f, date1904)
        return nil if f.negative? || f >= 2_958_466 # 9999-12-31
        return nil if !date1904 && f.floor == 60

        base =
          if date1904 then Time.utc(1904, 1, 1)
          elsif f < 60 then Time.utc(1899, 12, 31)
          else Time.utc(1899, 12, 30)
          end
        base + (f * 86_400).round
      end

      def time_of_day(f, code)
        secs = ((f % 1) * 86_400).round % 86_400
        secs = (f * 86_400).round if code.to_s.include?("[h]")
        h, rest = secs.divmod(3600)
        m, s = rest.divmod(60)
        strip_literals(code.to_s).match?(/s/i) ? format("%02d:%02d:%02d", h, m, s) : format("%02d:%02d", h, m)
      end

      # Fixed decimals, thousands separators and a leading currency symbol from the format's first
      # section. A negative keeps its minus sign (the parenthesised and red sections are not drawn).
      def decorate(f, code, suffix: "")
        section = code.split(";").first.to_s
        plain = strip_literals(section)
        decimals = plain[/\.([0#?]+)/, 1]&.length.to_i
        thousands = plain.match?(/[0#?],[0#?]/)
        symbol = currency_symbol(section)
        digits = format("%.#{decimals}f", f.abs.round(decimals))
        if thousands
          int, frac = digits.split(".")
          digits = int.reverse.scan(/\d{1,3}/).join(",").reverse + (frac ? ".#{frac}" : "")
        end
        "#{"-" if f.negative? && digits.match?(/[1-9]/)}#{symbol}#{digits}#{suffix}"
      end

      # `[$€-407]` or a bare `$`/`€`/`£`/`¥` before the first digit placeholder.
      def currency_symbol(section)
        bracket = section[/\[\$([^\]-]*)/, 1]
        return bracket if bracket.present?

        head = section.split(/[0#?]/, 2).first.to_s
        head.gsub(/"[^"]*"/, "")[CURRENCY].to_s
      end

      # A format's quoted text, escaped characters, `_x` spacers, `*x` fills and bracketed
      # sections (colours, locales, conditions) say nothing about whether it is a date — `"Day "0`
      # holds a `d` and is a number.
      def strip_literals(code)
        code.gsub(/"[^"]*"/, "").gsub(/\\./, "").gsub(/[_*]./, "").gsub(/\[(?!h\]|hh\]|m\]|mm\]|s\]|ss\])[^\]]*\]/i, "")
      end
    end
  end
end
