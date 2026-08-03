import { sections, buildArt } from "./tray_layout.js"

// Keeps a TrayLayout's `layout` ASCII art in sync with its sx/sy compartment sizes — the same job
// boxes.py's own web UI does in static/self.js (TrayLayoutInit). Ported from the tinkerex repo's
// traylayout_controller.js (a Stimulus controller) to a plain mount/destroy function.
//
// This is not decoration: `layout` OVERRIDES sx/sy. boxes.py reads the compartment sizes back out of
// the art, so the moment a layout is present, editing sx/sy changes nothing about the tray you get.
// Without this the two size fields are dead controls that silently disagree with the output.
//
// The starting art arrives already seeded by the sidecar (built by boxes.py's own TrayLayoutFile, so
// it is parseable by construction). This only keeps it honest as sx/sy change.
//
// Self-gating: it looks for layout + sx + sy and does nothing unless all three are present, so it is
// harmless on every other generator's form (GridfinityTrayLayout, for one, builds its layout from
// nx/ny/countx/county rather than sx/sy).
//
// root: the element containing the param fields, each marked data-param="<name>" (see fields.js).
export function mountTraySync(root) {
  const layout = root.querySelector('[data-param="layout"]')
  const sx = root.querySelector('[data-param="sx"]')
  const sy = root.querySelector('[data-param="sy"]')
  if (!layout || !sx || !sy) return { destroy() {} }

  // A layout loaded from a saved box is the user's own work — never regenerate over it unasked.
  // `data-prefilled` is set by fields.js exactly when this field was seeded from a prior save.
  let handEdited = layout.dataset.prefilled === "true"

  const build = () => buildArt(sections(sx.value), sections(sy.value))

  const update = () => {
    const art = build()
    if (art === null || art === layout.value) return
    if (handEdited && !confirm("You've edited this layout by hand. Regenerate it from the new sizes?")) return

    layout.value = art // assigning .value fires no "input" event, so this can't self-trigger
    handEdited = false
    layout.rows = Math.min(24, art.split("\n").length + 1)
  }

  const markEdited = () => { handEdited = true }
  const regenerate = () => update()
  layout.addEventListener("input", markEdited)
  // "change" (value committed on blur/Enter), NOT "input" as boxes.py's own page uses. Per
  // keystroke, "40*4" regenerates through its valid prefixes — you watch the tray become one 4mm
  // compartment, then one 40mm one — and on a hand-edited layout it asks for confirmation once per
  // CHARACTER.
  sx.addEventListener("change", regenerate)
  sy.addEventListener("change", regenerate)

  return {
    destroy() {
      layout.removeEventListener("input", markEdited)
      sx.removeEventListener("change", regenerate)
      sy.removeEventListener("change", regenerate)
    },
  }
}
