# THE WORDS NO RENDERED PAGE SAYS (2026-11-10, docs/superpowers/specs/
# 2026-11-10-hide-s3-sync-and-desktop-design.md). s3 and the sync server still run, but nothing a
# person reads names them, the sibling repos or the desktop client -- except text that renders only
# when the library is syncable, which describes the author's own chunk_remote deployment.
#
# ONE PATTERN FOR PAGES AND FILES (install_docs_test uses it too). `\s+` between two-word terms,
# because the install guide is hard-wrapped and "sync" at a line's end with "server" on the next is
# the likeliest way one slips back in (review, 2026-11-10); "Docker Desktop app" is Docker's.
module HiddenBackendWords
  PATTERN = /\bS3\b|\bbuckets?\b|chunk[_-]remote|sync[\s-]+servers?|sync\s+engines?|tinkerex-sync|tinkerex-client|(?<!docker\s)desktop\s+(?:app|client)s?/i

  def assert_no_hidden_backend_words(text, where)
    hits = text.scan(PATTERN)
    assert_empty hits, "#{where} says #{hits.uniq.join(', ')}"
  end

  # Every match in a file's text with its line number, so a failure points at the line to fix.
  # Leading comment and quote markers (`#`, `>`) come off each line first, one line for one line, so
  # a term wrapped across two comment lines of .env.example still reads as the two words it is --
  # with the markers left in, "sync\n# server" slipped past (mutation-checked, 2026-11-10).
  def self.hits_in(text)
    text = text.lines.map { |line| line.sub(/\A[ \t]*(?:#|>)+[ \t]?/, "") }.join
    text.to_enum(:scan, PATTERN).map do
      m = Regexp.last_match
      "#{text[0...m.begin(0)].count("\n") + 1}: #{m[0].gsub(/\s+/, ' ')}"
    end
  end
end
