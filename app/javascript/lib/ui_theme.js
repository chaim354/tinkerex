// WHICH THEME THE PAGE IS SHOWING, for the one kind of surface CSS cannot reach: a third-party
// viewer that takes its theme as a NAME at construction (KiCanvas). Everything else follows the
// theme through tokens and needs no JavaScript at all.
//
// Read from the same attribute the layout stamps (ShellHelper#ui_theme): "dark" is dark, "system"
// asks the OS with the same media query application.css puts Graphite under, and anything else is
// Paper. THE DEFAULT IS LIGHT (2026-10-08), matching ui_theme's own rule: an absent or junk cookie
// means Paper, and this is one of the places that default lives (design-system.md rule 4).
export function darkThemeActive() {
  const theme = document.documentElement.dataset.theme
  if (theme === "dark") return true
  if (theme === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches
  return false
}
