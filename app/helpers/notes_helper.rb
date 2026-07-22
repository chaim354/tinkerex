module NotesHelper
  # Markdown source -> sanitized HTML. `sanitize` is NOT optional: `body` is user input rendered as
  # HTML, and kramdown passes raw HTML (e.g. a `<script>`) straight through — so Rails' allow-list
  # sanitizer is what strips scripts, `javascript:` hrefs, and unknown tags while keeping the
  # markdown subset (headings, bold/italic, lists, links, code, blockquote).
  def render_note(body)
    sanitize(Kramdown::Document.new(body.to_s).to_html)
  end
end
