import { host, WouldReplaceError } from "@maker/addon-sdk"

// A bundle written the way docs/addon-api-v1.md tells an author to write one: it imports the SDK
// and touches `ctx` for nothing. Its job is to prove, in a real browser, that (a) the host pin
// resolves inside an addon's merged importmap, (b) initHost ran before this module was imported,
// (c) capabilities() answers the server's own map, and (d) files.save absorbs the 409 overwrite
// dance every bundle copies today.
//
// The destination and filename come from the QUERY STRING so the Ruby test can point the fixture at
// whatever project folder it just built, rather than the fixture hard-coding library state.
export default {
  mount(el, _ctx) {
    const q = new URLSearchParams(location.search)

    el.innerHTML = `<p data-role="sdk-level"></p>
      <p data-role="sdk-caps"></p>
      <button data-role="sdk-save">Save</button>
      <p data-role="sdk-status"></p>
      <button data-role="sdk-service-probe">Probe service</button>
      <p data-role="sdk-service"></p>`

    // Rendering the LEVEL proves initHost ran before this module was imported — a fixture that only
    // asserted its own text would pass with the binding still null.
    el.querySelector("[data-role=sdk-level]").textContent = `level ${host.level}`

    host.capabilities().then((caps) => {
      el.querySelector("[data-role=sdk-caps]").textContent =
        `write:${caps["library:write"]} read:${caps["library:read"]}`
    })

    el.querySelector("[data-role=sdk-save]").addEventListener("click", async () => {
      const status = el.querySelector("[data-role=sdk-status]")
      try {
        const result = await host.files.save({
          name: "sdk fixture save",
          folderNodeId: q.get("parent") || "",
          files: [ { name: q.get("fname"), contentType: "image/svg+xml", body: "<svg>sdk</svg>" } ],
          // Answering TRUE here is what exercises the re-POST with overwrite=1. A real bundle would
          // call window.confirm; the fixture answers deterministically so no dialog is involved.
          onReplace: (files) => {
            status.dataset.replaced = files.map((f) => `${f.name}@${f.folder}`).join(",")
            return true
          },
        })
        status.textContent = result.cancelled ? "Not saved." : "Saved."
      } catch (e) {
        // The typed error is the point: a bundle can say WHICH refusal happened, which is exactly
        // what today's hand-rolled "Save failed." cannot.
        status.textContent = e instanceof WouldReplaceError ? "Would replace." : `Failed: ${e.code}`
      }
    })

    // BOTH HALVES OF ONE URL. `service.get`'s first argument is the SERVICE NAME and its second is
    // the PATH; they are adjacent segments of the same URL, so a traversal in either is the same
    // defect and both must be refused before the request leaves the browser. Only a browser can
    // prove that: `/tools/sdk-fixture/service/../../evil/x` is normalized to `/tools/evil/x` BY THE
    // URL PARSER ITSELF, so the server's own guard never sees it — a request test would be asserting
    // about a URL the browser never sends.
    //
    // RENDERING THE ERROR'S CLASS AS WELL AS ITS CODE IS WHAT GIVES THE ASSERTION TEETH. Remove
    // either guard and the call reaches the network instead, the normalized URL matches no route,
    // and the SDK reports `ServiceError:service_error` — a DIFFERENT string rather than a missing
    // one, so the test fails on its own assertion and not merely on a console check.
    //
    // Depends on the host answering `service: true` (Maker::Addons::Host::CAPABILITIES). If that is
    // ever flipped off, `_require("service")` throws first and this reads
    // `UnsupportedCapabilityError:unsupported_capability` — loudly wrong, which is the right way to
    // find out.
    el.querySelector("[data-role=sdk-service-probe]").addEventListener("click", async () => {
      const attempt = async (fn) => {
        try { await fn(); return "no-error" } catch (e) { return `${e.name}:${e.code}` }
      }
      const name = await attempt(() => host.service.get("../../evil", "x"))
      const path = await attempt(() => host.service.get("fixture-svc", "../../evil"))
      el.querySelector("[data-role=sdk-service]").textContent = `name=${name} path=${path}`
    })
  },
}
