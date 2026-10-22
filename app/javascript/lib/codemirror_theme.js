// The code viewers' syntax colours: ONE HighlightStyle whose every colour is a design-system token
// (`var(--code-keyword)` …, defined per theme in application.css). The chrome — ground, gutters,
// active line, cursor, selection, search, tooltips, the merge view's tints — is CSS in
// vendor-overrides.css. One place, every editor: codeview, editor, diffview (and the history
// page's diffs through it), readme.
//
// THE SAME EXTENSIONS IN EVERY THEME, AND NOTHING IS CHOSEN AT MOUNT. This module used to read
// html[data-theme] when an editor mounted and add oneDark under the dark theme, so an editor already
// on screen kept the theme it mounted with until the next page. A colour that is a custom property
// is resolved by the browser at paint time instead: theme_controller.js#apply flips html[data-theme],
// the tokens change, and an open editor repaints with no Compartment, no listener and no remount.
// CodeMirror's own view therefore always runs its LIGHT base-theme variant (`&light`, no
// EditorView.darkTheme), and vendor-overrides.css repaints every colour that variant sets on what
// these editors show — which is why that sheet's rules are unscoped rather than per theme. Do not
// reintroduce a choice made at mount. test/system/code_theme_test.rb fails on both shapes it takes,
// MUTATION-CHECKED: a branch on html[data-theme] here (red on the editor mounted under Graphite) and
// a token resolved to a literal when the style is built (red on the live switch).
//
// basicSetup's defaultHighlightStyle is a FALLBACK highlighter, used only while no other is active,
// so adding this one replaces it rather than layering over it. Tags not named below inherit the
// editor's --fg.
let highlightStyle = null

function buildHighlightStyle(cm) {
  const t = cm.tags
  return cm.HighlightStyle.define([
    { tag: [t.keyword, t.controlKeyword, t.operatorKeyword, t.modifier, t.definitionKeyword, t.moduleKeyword],
      color: "var(--code-keyword)" },
    { tag: [t.string, t.special(t.string), t.regexp, t.character, t.escape], color: "var(--code-string)" },
    // color and unit are CSS's `#fff` and `px`, which the default style coloured with the literals.
    { tag: [t.number, t.bool, t.null, t.atom, t.color, t.unit], color: "var(--code-number)" },
    { tag: t.comment, color: "var(--code-comment)", fontStyle: "italic" },
    // special(variableName) is the legacy `variable-2` token (OpenSCAD's `$fn`, see
    // lib/codemirror_languages.js), grouped with macroName as the default style grouped it.
    // UNSTYLED, IT GETS NO SPAN AT ALL — CodeMirror wraps only the tokens a highlighter gives a
    // class — and code_viewer_test.rb's `$fn` assertion goes red, which is how this line was found.
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.definition(t.function(t.variableName)),
            t.macroName, t.special(t.variableName)],
      color: "var(--code-function)" },
    { tag: [t.typeName, t.className, t.namespace, t.definition(t.typeName)], color: "var(--code-type)" },
    { tag: [t.propertyName, t.attributeName, t.labelName], color: "var(--code-property)" },
    { tag: [t.meta, t.processingInstruction, t.annotation], color: "var(--code-meta)" },
    { tag: t.invalid, color: "var(--code-invalid)" },
    // Markdown (the README editor and every .md source view).
    { tag: t.heading, fontWeight: "bold" },
    { tag: [t.link, t.url], color: "var(--code-function)", textDecoration: "underline" },
    { tag: t.emphasis, fontStyle: "italic" },
    { tag: t.strong, fontWeight: "bold" },
    { tag: t.strikethrough, textDecoration: "line-through" }
  ])
}

// TAKES THE CODEMIRROR NAMESPACE AS AN ARGUMENT, like lib/codemirror_languages beside it and for
// its reason: this module must not import "codemirror" itself. The controllers reach the bundle
// through a dynamic import so it never ships on a page with no text file, and a static import here
// would put it back on every page that loads this module.
//
// BUILT ONCE PER PAGE LOAD, not per editor: HighlightStyle.define mints a style module and its
// generated class names, and a diff page mounts one editor per changed file. The namespace is the
// one bundle (§14d), so caching on the first caller's `cm` is caching on the only one there is.
export function themeExtensions(cm) {
  highlightStyle ??= buildHighlightStyle(cm)
  return [cm.syntaxHighlighting(highlightStyle)]
}
