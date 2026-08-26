// ext -> CodeMirror LanguageSupport (or a StreamLanguage), for codeview_controller.
//
// A HOST module, imported by that controller alone and DYNAMICALLY, so nothing here loads on a
// page with no text file. It takes the CodeMirror namespace as an ARGUMENT rather than importing
// "codemirror" itself: one module graph, one bundle, loaded once by the controller — and a static
// import here would pull 933 KB into every page that merely touches this file.
//
// THE DEFAULT IS NO LANGUAGE, NOT A GUESS. An unknown extension renders as plain text with line
// numbers, which is honest; highlighting a file as the wrong language is worse than not
// highlighting it, because it renders confidently wrong.
//
// gcode and scad are OURS. Neither exists in @codemirror/legacy-modes (checked, 6.5.3) and both
// are cheap: a simpleMode is a regex tokenizer over the StreamLanguage the bundle already ships.
// Do not reach for a full lezer grammar for either.
//
// A TOKEN NAME IS A LEGACY CodeMirror-5 NAME OR A BARE TAG — NEVER A DOTTED `tag.modifier`.
// @codemirror/language's stream parser resolves a dotted string left to right treating the LAST
// part as the tag, so `variableName.special` warns `Modifier special used at start of tag` on
// stderr and drops the modifier, while the legacy name `variable-2` resolves to exactly
// `variableName.special` with no warning. Measured against the shipped bundle, not reasoned:
// `variable-2` -> node `variableName.special`, warn []; `variableName.special` -> node
// `variableName_special`, warn ["Modifier special used at start of tag"]. The plan carried the
// dotted spelling; it would have printed a console warning on every OpenSCAD file.
export function languageFor(ext, cm) {
  switch (ext) {
    case "c": case "h": case "cpp": case "cc": case "hpp": case "ino": return cm.cpp()
    case "py": return cm.python()
    case "js": case "ts": return cm.javascript({ typescript: ext === "ts" })
    case "json": return cm.json()
    case "md": case "markdown": return cm.markdown()
    case "yml": case "yaml": return cm.yaml()
    case "xml": return cm.xml()
    case "html": return cm.html()
    case "css": return cm.css()
    case "rs": return cm.rust()
    case "go": return cm.go()
    case "sql": return cm.sql()
    case "sh": return cm.StreamLanguage.define(cm.shell)
    case "toml": case "ini": case "cfg": case "conf": return cm.StreamLanguage.define(cm.toml)
    case "gcode": case "gco": case "nc": case "tap": case "ngc":
      return cm.StreamLanguage.define(cm.simpleMode(GCODE))
    // UNREACHABLE THROUGH THE FILE PAGE TODAY, AND KEPT ANYWAY — say so rather than let a reader
    // assume it works. `Maker::FileAttachment.role_for("x.scad")` is `cad_source`, which is not in
    // `TEXT_ROLES`, so `FilesController#preview_kind("x.scad")` answers `:other` and this branch
    // is never reached from a file's detail page (driven, not assumed). Making it reachable is a
    // ROLE change — `scad` moving from `cad_source` to `code`, which also moves where
    // Maker::ProjectFolders files it and needs a re-derive migration for existing attachment rows
    // — so it belongs with that decision, not here. The mode itself is real and probed.
    case "scad": return cm.StreamLanguage.define(cm.simpleMode(OPENSCAD))
    default: return null
  }
}

// `lbrn`/`lbrn2` are DELIBERATELY ABSENT even though they are XML. `preview_kind` answers
// `:measure` for lbrn, lbrn2, mage, dxf and svg — that branch owns those pages — so an entry for
// them here could never run, and one that reads as coverage is worse than none.

// G-code. Comments are BOTH `( … )` and `; …` — the two dialects in this app's own vocabulary
// (LinuxCNC/GRBL `;`, Fanuc-style parentheses) — and a mode handling only one renders half a
// file as code. The axis-letter rule uses a LOOKAHEAD so `X` and `10.5` are two tokens (an
// address and its number) rather than the letter swallowing the digits.
const GCODE = {
  start: [
    { regex: /\(.*?\)/, token: "comment" },
    { regex: /;.*/, token: "comment" },
    { regex: /^%/, token: "meta" },
    { regex: /[GgMm]\d+(?:\.\d+)?/, token: "keyword" },
    { regex: /[NnTtSsFf]\d+/, token: "atom" },
    { regex: /[A-Za-z](?=[-+]?[\d.])/, token: "variableName" },
    { regex: /[-+]?(?:\d*\.\d+|\d+\.?)/, token: "number" }
  ]
}

// OpenSCAD. C-like, so the token set is small; `include`/`use` take `<angle>` paths rather than
// quoted strings, which is why they get their own rule before the string rule. `variable-2` is
// the legacy name for `variableName.special` — see the header for why it is not spelled that way.
const OPENSCAD = {
  start: [
    { regex: /\/\/.*/, token: "comment" },
    { regex: /\/\*/, token: "comment", next: "comment" },
    { regex: /(?:include|use)\s*<[^>]*>/, token: "meta" },
    { regex: /"(?:[^\\"]|\\.)*"/, token: "string" },
    { regex: /\b(?:module|function|if|else|for|intersection_for|let|each|true|false|undef)\b/,
      token: "keyword" },
    { regex: /\b(?:cube|sphere|cylinder|polyhedron|square|circle|polygon|text|linear_extrude|rotate_extrude|translate|rotate|scale|mirror|multmatrix|color|offset|hull|minkowski|union|difference|intersection|render|surface|projection|import|children)\b/,
      token: "builtin" },
    { regex: /\$[A-Za-z_]\w*/, token: "variable-2" },
    { regex: /[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/, token: "number" }
  ],
  comment: [
    { regex: /.*?\*\//, token: "comment", next: "start" },
    { regex: /.*/, token: "comment" }
  ],
  languageData: { commentTokens: { line: "//", block: { open: "/*", close: "*/" } } }
}
