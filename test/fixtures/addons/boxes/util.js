// Small ports of Tools::BoxesHelper (tinkerex repo, app/helpers/tools/boxes_helper.rb) that had no
// Rails dependency of their own — string shaping, not routing or auth. Kept in one file because
// both are used by both gallery.js and editor.js.

// Port of `box_section_id`. Stable DOM id for a section, so a table of contents can link to it and
// the sections behaviour (sections.js) can remember whether it was left open. Ruby's `parameterize`
// lowercases, collapses runs of non-alphanumerics to "-", and strips leading/trailing "-"; this is
// the same shape for the plain-ASCII generator/section names boxes.py actually produces. A heading
// that is all punctuation parameterizes to "" in Ruby too — same "other" fallback here.
export function sectionId(section, prefix = "box-section") {
  const slug = String(section ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
  return `${prefix}-${slug || "other"}`
}

// Port of `box_help`. boxes.py appends a Markdown manual link — "[<glyph>](https://…)" — to many
// option help strings. Rendered verbatim it dumps the glyph + raw URL inline and wraps the field.
// Split into [visible_text, manual_url] so the caller can show clean help plus one compact link.
// Anchored to the END so ordinary parentheses like "(in mm)" are left alone.
const MANUAL_LINK = /\s*\[[^\]]*\]\((https?:\/\/[^)\s]+)\)\s*$/
export function boxHelp(help) {
  const text = String(help ?? "")
  const m = text.match(MANUAL_LINK)
  if (m) return [ text.replace(MANUAL_LINK, "").trim(), m[1] ]
  return [ text.trim(), null ]
}

// Clamp, used for the multiline textarea's rows/cols sizing (port of `.clamp(min, max)`).
export function clamp(n, min, max) {
  return Math.min(Math.max(n, min), max)
}

// Ruby's String#lines, which fields.js's textarea sizing depends on for a byte-for-byte match with
// the original's `val.to_s.lines`. Ruby keeps each line's trailing "\n" attached and produces no
// extra trailing entry for a string that itself ends in "\n" — `"a\nb\n".lines` is 2 elements, not
// 3. `String#split("\n")` alone over-counts by one in exactly that case (a trailing empty string for
// the delimiter after the last real line), which would round a textarea's row count up by one.
export function rubyLines(text) {
  if (text === "") return []
  const parts = text.split("\n")
  if (text.endsWith("\n")) parts.pop()
  return parts
}
