// The source of vendor/javascript/codemirror.js. NOT PINNED — bin/build-codemirror bundles this
// into the single file config/importmap.rb pins, and no importmap specifier resolves to this file,
// so no page ever imports it. (It is NOT "never served": vendor/javascript is on Propshaft's asset
// path, so this file IS digest-copied into public/assets like every other file in this directory.
// Unreachable-by-specifier is the true claim; unserved is not, and saying so would be a comment
// that reads as a guarantee nothing provides.)
//
// FOUR EXPORTS ARE UNUSED TODAY — keymap, lineNumbers, highlightActiveLine, Compartment — and they
// are kept deliberately: basicSetup already pulls the whole of @codemirror/view and
// @codemirror/state, so naming them costs nothing measurable, and they are the primitives the
// deferred editing arc needs (Compartment is how a read-only view is later made editable without
// rebuilding the state). Removing them would shrink the bundle by approximately zero and
// invalidate the size figure bin/build-codemirror prints.
export { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view"
export { EditorState, Compartment } from "@codemirror/state"
export { unifiedMergeView, getChunks, rejectChunk } from "@codemirror/merge"
export { basicSetup } from "codemirror"
// The dark editor theme. Which one a page uses is app/javascript/lib/codemirror_theme.js's
// decision, read from html[data-theme]; this export is only how it reaches the controllers.
export { oneDark } from "@codemirror/theme-one-dark"
export { StreamLanguage } from "@codemirror/language"
export { cpp } from "@codemirror/lang-cpp"
export { python } from "@codemirror/lang-python"
export { javascript } from "@codemirror/lang-javascript"
export { json } from "@codemirror/lang-json"
export { markdown } from "@codemirror/lang-markdown"
export { yaml } from "@codemirror/lang-yaml"
export { xml } from "@codemirror/lang-xml"
export { html } from "@codemirror/lang-html"
export { css } from "@codemirror/lang-css"
export { rust } from "@codemirror/lang-rust"
export { go } from "@codemirror/lang-go"
export { sql } from "@codemirror/lang-sql"
export { shell } from "@codemirror/legacy-modes/mode/shell"
export { toml } from "@codemirror/legacy-modes/mode/toml"
export { simpleMode } from "@codemirror/legacy-modes/mode/simple-mode"
