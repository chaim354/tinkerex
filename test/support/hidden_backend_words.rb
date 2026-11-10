# THE WORDS NO RENDERED PAGE SAYS (2026-11-10, docs/superpowers/specs/
# 2026-11-10-hide-s3-sync-and-desktop-design.md). s3 and the sync server still run, but nothing a
# person reads names them, the sibling repos or the desktop client -- except text that renders only
# when the library is syncable, which describes the author's own chunk_remote deployment.
module HiddenBackendWords
  PATTERN = /\bS3\b|\bbuckets?\b|chunk[_-]remote|sync[ -]server|sync engine|tinkerex-sync|tinkerex-client|desktop (?:app|client)s?/i

  def assert_no_hidden_backend_words(text, where)
    hits = text.scan(PATTERN)
    assert_empty hits, "#{where} says #{hits.uniq.join(', ')}"
  end
end
