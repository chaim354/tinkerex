// Which CodeMirror theme a page wants, read from the same attribute the layout stamps
// (ShellHelper#ui_theme): "dark" and "system"-resolving-to-dark get oneDark; "light" gets
// CodeMirror's default (this app's vendor-overrides paint the chrome). One place, three editors.
//
// READ AT MOUNT, NOT WATCHED. theme_controller.js writes the cookie and flips
// html[data-theme] live, so an editor already on screen keeps the theme it mounted with until
// the page is next rendered. Following the flip means a Compartment per view and a listener per
// controller; the trade is deliberate and the fix, if it is ever wanted, is that — not a
// reconfigure bolted onto one of the three.
//
// THE DEFAULT IS DARK, matching ui_theme's own rule: an absent or junk cookie means dark, and a
// junk value never reaches this attribute anyway (the server only ever writes the enum).
export function darkThemeActive() {
  const theme = document.documentElement.dataset.theme
  if (theme === "light") return false
  if (theme === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches
  return true
}

// TAKES THE CODEMIRROR NAMESPACE AS AN ARGUMENT, like lib/codemirror_languages beside it and for
// its reason: this module must not import "codemirror" itself. The three controllers reach the
// bundle through a dynamic import so it never ships on a page with no text file, and a static
// import here would put it back on every page that loads this module.
export function themeExtensions(cm) {
  return darkThemeActive() ? [cm.oneDark] : []
}
