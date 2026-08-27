import { label } from "fixture-dep"
import { saveWithOverwrite } from "./save.js"

// Minimal addon bundle, owned by test/system/addon_bundle_test.rb. Its only job is to prove the
// HOST PIPELINE works end to end in a real browser: Tools::AddonsController#show renders the shell
// -> the Stimulus addon_controller.js dynamic-imports this file through the same-origin asset proxy
// (#asset) -> the browser resolves the bare "fixture-dep" specifier through the merged importmap
// (host pins + this addon's `pins`) -> mount(element, context) runs. Rendering the pinned module's
// own value into the DOM means a passing assertion proves the PIN resolved, not merely that this
// entry module loaded — a fixture that only asserted its own text could pass with `pins` broken.
//
// IT ALSO EXERCISES save.js — WHICH IS NO LONGER THE CODE THAT SHIPS, AND THIS COMMENT USED TO SAY
// IT WAS. save.js was a verbatim copy of the helper every real bundle imported; `@maker/addon-sdk`
// then absorbed that dance (`host.files.save({onReplace})`) and the bundles moved to it
// (boxes/boxes.js's own header records the move), so nothing published imports a save.js today and
// this copy has already drifted from the SDK on wire shape — it reads only the FLAT
// `{error: "would_replace"}` body, where addon_sdk.js's errorFrom reads the nested shape too.
// THE SHIPPED OVERWRITE FLOW IS ASSERTED AGAINST THE SDK, in test/system/addon_sdk_test.rb, which
// owns all three of its answers — accept, decline, no callback; nothing here proves anything about
// that code.
//
// WHAT IT STILL PROVES, AND WHY THE FILE STAYS: manifests.json's `sdk-fixture` entry records that
// `fixture` deliberately holds the RAW-CTX path — `ctx.saveUrl`, `ctx.csrfToken`, a hand-rolled
// fetch, importing nothing — so both halves of the compatibility rule are covered by something that
// runs. save.js is that path's save, and its behaviour is pure client-side (a 409 from the host, a
// window.confirm, a re-POST carrying overwrite=1), none of which any request test can observe.
//
// The destination and filename come from the QUERY STRING so the Ruby test can point one fixture at
// whatever project folder it just built, rather than the fixture hard-coding library state.
// IT ALSO EXERCISES ctx.chooseFolder, the host-provided folder chooser, for the same reason it
// exercises save.js: that contract is a FUNCTION the host hands across, and whether a bundle can
// actually call it — modal opens, columns fetch, promise resolves with {nodeId, path}, cancel
// resolves null — is observable nowhere but a browser. The feature-detect below is not defensive
// padding either; it is the shape every real bundle uses, because a bundle image can be published
// (or rolled back) against a host that predates this key.
export default {
  mount(el, ctx) {
    const q = new URLSearchParams(location.search)
    el.innerHTML = `<p data-role="fixture-output">${label}</p>
      <button data-role="fixture-choose">Choose folder</button>
      <p data-role="fixture-folder">${ctx.defaultFolderLabel || "(none)"}</p>
      <button data-role="fixture-save">Save</button>
      <p data-role="fixture-status"></p>`

    let chosen = null // null = "the bundle never chose", distinct from "" = the library root
    el.querySelector("[data-role=fixture-choose]").addEventListener("click", async () => {
      if (typeof ctx.chooseFolder !== "function") {
        el.querySelector("[data-role=fixture-folder]").textContent = "(no chooser on this host)"
        return
      }
      const selection = await ctx.chooseFolder()
      // A CANCEL MUST NOT MOVE THE DESTINATION. Resolving null and resolving {nodeId: ""} are two
      // different answers and this is the line that proves the bundle side can tell them apart.
      if (!selection) {
        el.querySelector("[data-role=fixture-folder]").textContent += " (cancelled)"
        return
      }
      chosen = selection.nodeId
      el.querySelector("[data-role=fixture-folder]").textContent = selection.path
    })

    el.querySelector("[data-role=fixture-save]").addEventListener("click", async () => {
      const body = new FormData()
      body.append("name", "fixture save")
      body.append("data", "{}")
      // The chooser's answer WINS over the query string when the bundle made one — so a passing
      // save assertion proves the node_id travelled all the way from the modal into the request,
      // not merely into a <p>.
      body.append("parent_node_id", chosen !== null ? chosen : (q.get("parent") || ""))
      body.append("files", JSON.stringify([
        { name: q.get("fname"), content_type: "image/svg+xml", body: "<svg>v2</svg>" },
      ]))
      const { res, cancelled } = await saveWithOverwrite(ctx.saveUrl, body, ctx.csrfToken)
      el.querySelector("[data-role=fixture-status]").textContent =
        cancelled ? "Not saved." : res.ok ? "Saved." : "Save failed."
    })
  }
}
