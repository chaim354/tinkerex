import { mountGallery } from "./gallery.js"
import { mountEditor } from "./editor.js"
import { mountShow } from "./show.js"

// The Box Generator addon. Its only contract with the host is `mount(element, context)` — no
// Stimulus, no host framework — exactly like addons/generators/generators.js. Everything the
// retired Rails controller (Tools::BoxesController) did server-side — grouping generators into
// sections, filtering, folding/remembering sections, grouping saved boxes into a rail, the editor's
// param form, its live preview, its tray-layout sync and top-view plan, and saving — now happens
// here, talking to the sidecar through ctx.serviceUrl and to the host's generic save/states doors.
//
// This is a small client-side router over ONE mounted <div>, not three separate Rails pages: the
// gallery, the per-generator editor, and a saved box's detail view are three functions
// (gallery.js/editor.js/show.js) that each render into the same root and return a destroy callback,
// swapped in and out by the functions below. Every module here is a plain function, not a class or a
// component framework — consistent with the "no host framework" contract this bundle itself honours.
export default {
  async mount(el, ctx) {
    el.innerHTML = `<div data-role="boxes-page"></div>`
    const page = el.querySelector('[data-role="boxes-page"]')

    let generators = []
    let states = []
    let destroyCurrent = null

    const swap = (render) => {
      destroyCurrent?.()
      destroyCurrent = render() || null
    }

    const showGallery = () =>
      swap(() => mountGallery(page, { generators, states, ctx, onOpenGenerator: showEditor, onOpenState: showState }))

    const showEditor = (key, prefillValues) => {
      const generator = generators.find((g) => g.key === key)
      if (!generator) { showGallery(); return } // an unknown/removed generator key -> back to the gallery
      swap(() => mountEditor(page, {
        generator, states, ctx, prefillValues,
        onBack: showGallery,
        onOpenGenerator: showEditor,
        // Refresh the saved-states list in the background so the gallery's rail and any editor
        // reopened later reflect the new save — but deliberately does NOT navigate away: the
        // editor's own inline "Saved." status is the confirmation, matching generators.js's own
        // "stay put after a save" pattern so further tweaks don't require reopening the generator.
        onSaved: async () => { try { states = await fetchStates(ctx) } catch (_e) { /* keep the stale list */ } },
      }))
    }

    const showState = (state) =>
      swap(() => mountShow(page, { state, ctx, onBack: showGallery, onDuplicate: showEditor }))

    try {
      [ generators, states ] = await Promise.all([ fetchGenerators(ctx), fetchStates(ctx) ])
    } catch (e) {
      // Mirrors BoxesController#require_boxes!'s graceful degrade (unconfigured sidecar -> a
      // message, not a crash) — this bundle has no host redirect to reach for, so it renders the
      // message in place instead.
      page.innerHTML = `<p class="muted">Box Generator is unavailable: ${escapeHtml(e.message)}</p>`
      return
    }

    showGallery()
  },
}

async function fetchGenerators(ctx) {
  const res = await fetch(`${ctx.serviceUrl}boxes/generators`)
  if (!res.ok) throw new Error(`could not reach the sidecar (${res.status})`)
  return res.json()
}

async function fetchStates(ctx) {
  const res = await fetch(ctx.statesUrl)
  if (!res.ok) throw new Error(`could not load saved boxes (${res.status})`)
  return res.json()
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
