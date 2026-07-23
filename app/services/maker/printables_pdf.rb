module Maker
  # Parse a Printables model PDF's TEXT (as produced by pdfium) into model metadata. PURE:
  # (text, filename, title) -> a Hash of only the fields it found. Tuned to how pdfium reads a
  # Printables PDF (values exploded across lines, icon-font glyphs as stray single letters, the
  # title/author block emitted AFTER the changelog), so every field is anchored by pattern, never
  # by absolute position; a miss omits the key instead of raising. A non-Printables PDF yields
  # little, gracefully. Validated against test/fixtures/files/printables_honeycomb_pdfium.txt.
  module PrintablesPdf
    module_function

    MATERIALS = %w[PCTG PETG NYLON PLA PET ABS TPU ASA PVA HIPS PP PA PC].freeze # longest-first

    def extract(text:, filename: nil, title: nil)
      lines = text.to_s.scrub.split("\n").map { |l| l.gsub(/\s+/, " ").strip }
      {
        designer:       designer(lines, title),
        license:        license(lines),
        description:    description(lines),
        tags:           tags(lines),
        source_url:     source_url(filename),
        print_settings: print_settings(lines)
      }.reject { |_, v| v.blank? }
    end

    # Author sits above the title, which sits above the "VIEW IN BROWSER" button. We know the
    # model's title, so peel the title lines off (all their words are in the title); the first line
    # above them is the author.
    def designer(lines, title)
      i = lines.index("VIEW IN BROWSER")
      return nil unless i
      title_words = title.to_s.downcase.scan(/[a-z0-9]+/)
      return nil if title_words.empty?
      j = i - 1
      j -= 1 while j >= 0 && (w = lines[j].downcase.scan(/[a-z0-9]+/)).any? && w.all? { |x| title_words.include?(x) }
      # nothing above matched the title (j unchanged), or the whole preamble was title words (j
      # ran off the top). Either way there's no reliable author anchor — omit it, don't let a
      # negative index wrap to lines[-1] (the last line of the PDF) and fabricate a designer.
      return nil if j == i - 1 || j.negative?
      author = lines[j].to_s.strip
      return nil if author.blank? || author.length > 40 || author.include?(">")
      author
    end

    def license(lines)
      i = lines.index { |l| l == "License" || l.start_with?("This work is licensed") }
      i && normalize_license(lines[i, 5].join(" "))
    end

    def normalize_license(str)
      d = str.downcase
      return "CC0 (Public Domain)" if d.include?("public domain") || d.include?("cc0")
      return nil unless d.include?("creative commons") || d.include?("attribution")
      parts = [ "CC BY" ]
      parts << "NC" if d.include?("noncommercial") || d.include?("non-commercial")
      parts << "SA" if d.include?("sharealike") || d.include?("share-alike")
      parts << "ND" if d.include?("noderiv")
      [ parts.join("-"), str[/\b(\d\.\d)\b/, 1] ].compact.join(" ")
    end

    def description(lines)
      i = lines.index("Summary")
      return nil unless i
      body = []
      lines[(i + 1)..].each do |l|
        break if l.blank? || l.match?(/\A.+\s>\s.+\z/) || l.start_with?("News", "Tags:")
        body << l
      end
      body.join(" ").presence
    end

    def tags(lines)
      line = lines.find { |l| l.start_with?("Tags:") }
      line&.sub(/\ATags:\s*/, "")&.split(/\s+/)&.reject(&:blank?)
    end

    def source_url(filename)
      id = filename.to_s[/\A(\d+)-/, 1]
      id && "https://www.printables.com/model/#{id}"
    end

    def print_settings(lines)
      ps = {}
      mm = lines.select { |l| l.match?(/\A[\d.]+\s*mm\z/) }
      ps["layer_height"] = mm[0] if mm[0]
      ps["nozzle"]       = mm[1] if mm[1]
      ps["print_time"] = lines.find { |l| l.match?(/\A[\d.]+\s*hrs\z/) }
      ps["material"]   = lines.find { |l| MATERIALS.include?(l.upcase) }
      ps["filament"]   = lines.find { |l| l.match?(/\A\d+\s*g\z/) }
      ps["category"]   = lines.find { |l| l.match?(/\A[^>]+\s>\s.+\z/) && !l.start_with?("Tags") }
      if (gi = lines.index { |l| l.match?(/\A\d+\s*g\z/) })
        printer = []
        lines[(gi + 1)..].each do |l|
          next if l.length <= 1 # icon glyph
          break if l.blank? || l == "Summary" || l.match?(/\A[\d.]/)
          printer << l
          break if printer.join(" ").length > 30
        end
        ps["printer"] = printer.join(" ").presence
      end
      ps.compact
    end
  end
end
