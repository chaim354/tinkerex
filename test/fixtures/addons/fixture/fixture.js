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
// IT ALSO EXERCISES save.js, which is a VERBATIM COPY of the helper all three real bundles import
// (chaim354/tinkerex-addons addons/<key>/save.js). That helper is the only new logic in the
// overwrite-confirmation flow, and it is pure client-side behaviour — a 409 from the host, a
// window.confirm, a re-POST carrying overwrite=1 — none of which any request test can observe. The
// real bundles are the addons repo's business (see the header note above); what this proves is that
// the helper and the host's 409 contract actually agree, in a browser, against the real endpoint.
//
// The destination and filename come from the QUERY STRING so the Ruby test can point one fixture at
// whatever project folder it just built, rather than the fixture hard-coding library state.
export default {
  mount(el, ctx) {
    const q = new URLSearchParams(location.search)
    el.innerHTML = `<p data-role="fixture-output">${label}</p>
      <button data-role="fixture-save">Save</button>
      <p data-role="fixture-status"></p>`

    el.querySelector("[data-role=fixture-save]").addEventListener("click", async () => {
      const body = new FormData()
      body.append("name", "fixture save")
      body.append("data", "{}")
      body.append("parent_node_id", q.get("parent") || "")
      body.append("files", JSON.stringify([
        { name: q.get("fname"), content_type: "image/svg+xml", body: "<svg>v2</svg>" },
      ]))
      const { res, cancelled } = await saveWithOverwrite(ctx.saveUrl, body, ctx.csrfToken)
      el.querySelector("[data-role=fixture-status]").textContent =
        cancelled ? "Not saved." : res.ok ? "Saved." : "Save failed."
    })
  }
}
