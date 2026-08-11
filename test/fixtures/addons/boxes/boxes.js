import { mountGallery } from "./gallery.js"
import { mountEditor } from "./editor.js"
import { mountShow } from "./show.js"
// THE HOST SDK, NOT A HAND-ROLLED fetch. "@maker/addon-sdk" is pinned by the host into every addon
// page's merged importmap — never vendor a copy, never pin it in manifests.json, never import it by
// path (docs/addon-api-v1.md §3). It is what absorbed this bundle's old save.js.
//
// `host` IS A LIVE BINDING: read through it at CALL time and never destructure at module top level.
// A top-level `const { service } = host` SUCCEEDS on first load, which is what makes it dangerous —
// an ES module is evaluated once per URL per page while the host is rebuilt on every mount, so
// after a Turbo navigation away and back the captured value goes on serving the PREVIOUS,
// torn-down host's context and CSRF token, with nothing thrown and nothing logged.
//
// THIS STATIC IMPORT IS WHAT MAKES THE BUNDLE SDK-ONLY, AND `min_host: 1` DOES NOT PROTECT IT.
// manifests.json now declares `min_host: 1`, but that key can only bind a host that UNDERSTANDS it:
// a host published before `min_host` existed ignores it, lists the addon as usual, loads this
// module, and then fails to resolve "@maker/addon-sdk" — the page reads "This tool failed to load"
// and no code here ever runs. The recovery is on the publishing side: `bin/rollback <earlier-sha>`
// in this repo puts the pre-SDK bundle image back.
import { host, AddonError } from "@maker/addon-sdk"

// The Box Generator addon. Its only contract with the host is `mount(element, context)` — no
// Stimulus, no host framework — exactly like addons/generators/generators.js. Everything the
// retired Rails controller (Tools::BoxesController) did server-side — grouping generators into
// sections, filtering, folding/remembering sections, grouping saved boxes into a rail, the editor's
// param form, its live preview, its tray-layout sync and top-view plan, and saving — now happens
// here, talking to the sidecar and to the host's save/states doors through the SDK.
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
        onSaved: async () => { try { states = await fetchStates() } catch (_e) { /* keep the stale list */ } },
      }))
    }

    const showState = (state) =>
      swap(() => mountShow(page, { state, ctx, onBack: showGallery, onDuplicate: showEditor }))

    try {
      [ generators, states ] = await Promise.all([ fetchGenerators(), fetchStates() ])
    } catch (e) {
      // Mirrors BoxesController#require_boxes!'s graceful degrade (unconfigured sidecar -> a
      // message, not a crash) — this bundle has no host redirect to reach for, so it renders the
      // message in place instead.
      page.innerHTML = `<p class="muted">Box Generator is unavailable: ${escapeHtml(e.message)}</p>`
      // Anything that is not an AddonError is a bug in THIS bundle rather than a refusal from the
      // host or the sidecar, and it must still reach the console. NOT rethrown, which is the
      // difference from generators.js's save handler: that one throws from inside a click listener,
      // where nothing consumes the rejection. This is inside mount(), which addon_controller.js
      // awaits inside its own try — a rejection there OVERWRITES mountTarget.textContent with
      // "This tool failed to load", discarding the tailored degrade message rendered one line above
      // and reporting a reachable sidecar outage as a broken bundle.
      if (!(e instanceof AddonError)) console.error(e)
      return
    }

    showGallery()
  },
}

// THE SERVICE NAME AND THE PATH ARE TWO ARGUMENTS, NOT ONE STRING. The old call appended
// "boxes/generators" to ctx.serviceUrl by hand; the route is `tools/:key/service/:service/*path`, so
// the leading "boxes" was always the SERVICE segment rather than part of the path. Passing it
// separately is what lets the SDK refuse a "." / ".." / empty service name — a traversal the browser
// would otherwise normalize away before the request was sent, misrouting silently instead of being
// refused (see encodeServiceName in the SDK).
//
// `service.get` THROWS on a non-ok response rather than returning it, and the thrown ServiceError
// carries the sidecar's own raw text — so the degrade message below shows what the sidecar actually
// said (an unreachable/unconfigured one is a body-less 404, which reads as "Service request failed
// (404)") instead of a status code this bundle re-worded.
async function fetchGenerators() {
  const res = await host.service.get("boxes", "generators")
  return res.json()
}

async function fetchStates() {
  return host.state.list()
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
