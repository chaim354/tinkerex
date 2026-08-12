import { host, WouldReplaceError } from "@maker/addon-sdk"

// A bundle written the way docs/addon-api-v1.md tells an author to write one: it imports the SDK
// and touches `ctx` for nothing. Its job is to prove, in a real browser, that (a) the host pin
// resolves inside an addon's merged importmap, (b) initHost ran before this module was imported,
// (c) capabilities() answers the server's own map, (d) files.save absorbs the 409 overwrite dance
// every bundle copies today, and (e) the service plane — its transport, its URL builder and its
// abort handling — behaves in a real browser, which for the transport is the ONLY place it can be
// observed at all (see ART below).
//
// The destination and filename come from the QUERY STRING so the Ruby test can point the fixture at
// whatever project folder it just built, rather than the fixture hard-coding library state.

// MULTI-LINE ON PURPOSE, AND THE WHOLE POINT OF THE POST PROBE BELOW. This mirrors boxes.py's
// TrayLayout input, whose entire meaning is line-by-line ASCII art. Under the SDK's old FormData
// transport the browser's multipart serializer rewrote every "\n" here as "\r\n" AFTER `append`,
// so the sidecar silently parsed the wrong tray — and no unit assertion could see it, because the
// corruption happens inside the browser, between the bundle's call and the wire.
const ART = "+-+-+-+\n| | | |\n+-+-+-+\n"

// THE BINARY PAYLOAD, CHOSEN SO NOTHING CAN LAUNDER IT QUIETLY. A PNG signature carries a literal
// CR LF pair, and 0xFF 0xFE is a lone UTF-16 BOM that is not valid UTF-8 at all. Any layer that
// decoded, re-encoded or newline-normalized these bytes on the way through would change them
// visibly — which an ASCII payload would let it get away with.
const BYTES = new Uint8Array([ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff, 0xfe ])

// A MULTI-LINE TEXT FILE, THE OTHER HALF OF THE SAME PROOF AND THE EASIER HALF TO GET WRONG.
// `service.post`'s CRLF incident (see ART above) was a text value crossing a multipart TEXT field;
// a FILE's content must never do that either. This travels as a plain string, which the SDK keeps
// inside the JSON `files` field, where JSON escaping leaves the serializer no newline to rewrite.
const TEXT = "line one\nline two\n"

// Rendered rather than compared in the bundle, so the Ruby side asserts on the bytes themselves.
const hex = (buf) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("")

// LINE ENDINGS MADE VISIBLE. A textContent assertion cannot tell "line one\nline two" from
// "line one\r\nline two" — Capybara normalizes whitespace, so the very corruption under test would
// be invisible in the one place it is observable. Spelling the terminators out is what makes a CRLF
// regression a STRING MISMATCH rather than a passing test.
const showEndings = (text) => text.replaceAll("\r", "<CR>").replaceAll("\n", "<LF>")

export default {
  mount(el, _ctx) {
    const q = new URLSearchParams(location.search)

    el.innerHTML = `<p data-role="sdk-level"></p>
      <p data-role="sdk-caps"></p>
      <button data-role="sdk-save">Save</button>
      <p data-role="sdk-status"></p>
      <button data-role="sdk-service-probe">Probe service</button>
      <p data-role="sdk-service"></p>
      <textarea data-role="sdk-art"></textarea>
      <button data-role="sdk-post">Post art</button>
      <p data-role="sdk-post-result"></p>
      <p data-role="sdk-service-url"></p>
      <button data-role="sdk-url-probe">Probe url guards</button>
      <p data-role="sdk-url-guards"></p>
      <button data-role="sdk-abort-probe">Probe abort</button>
      <p data-role="sdk-abort"></p>
      <button data-role="sdk-roundtrip">Save and read back</button>
      <p data-role="sdk-roundtrip-result"></p>
      <button data-role="sdk-pick">Pick a file</button>
      <p data-role="sdk-picked"></p>`

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

    // THE TRANSPORT PROBE. Reads a REAL <textarea>'s `.value` rather than posting the string
    // literal directly: a textarea is where a multi-line addon param actually comes from, and the
    // DOM guarantees that value is LF-clean, so any "\r" the Ruby side sees was introduced by the
    // transport and by nothing else. The nested object rides along in the same call because the
    // old FormData path broke both at once — it flattened `{depth: 3}` to "[object Object]".
    const art = el.querySelector("[data-role=sdk-art]")
    art.value = ART
    el.querySelector("[data-role=sdk-post]").addEventListener("click", async () => {
      const out = el.querySelector("[data-role=sdk-post-result]")
      try {
        const res = await host.service.post("fixture-svc", "echo", {
          layout: art.value,
          nested: { generator: "TrayLayout", depth: 3 },
        })
        out.textContent = await res.text()
      } catch (e) {
        out.textContent = `${e.name}:${e.code}`
      }
    })

    // THE URL BUILDER, RENDERED RATHER THAN FETCHED — which is the property under test. If `url`
    // ever performed a request, this line would be async and could not fill a textContent
    // synchronously during mount.
    el.querySelector("[data-role=sdk-service-url]").textContent =
      host.service.url("fixture-svc", "sample/a b")

    // AND ITS GUARDS, WHICH ARE THE REASON IT IS A HOST FUNCTION AT ALL. A builder handing back a
    // raw string for `<img src>` is the one place a traversal would never be refused later — there
    // is no request for a server guard to inspect, only an attribute the browser dereferences. So
    // it must refuse exactly what get/post refuse, and this proves it does rather than trusting
    // that the shared helper was in fact shared.
    el.querySelector("[data-role=sdk-url-probe]").addEventListener("click", () => {
      const attempt = (fn) => {
        try { fn(); return "no-error" } catch (e) { return `${e.name}:${e.code}` }
      }
      const name = attempt(() => host.service.url("../../evil", "x"))
      const path = attempt(() => host.service.url("fixture-svc", "../../evil"))
      el.querySelector("[data-role=sdk-url-guards]").textContent = `name=${name} path=${path}`
    })

    // THE ABORT PROBE — TWO CASES, AND THE SECOND IS THE ONE WITH TEETH.
    //
    // Both signals are aborted BEFORE the call, so fetch rejects immediately and nothing depends on
    // timing. The first uses a bare `abort()` (a DOMException named "AbortError"); the second uses
    // `abort(reason)`, which makes fetch reject with THAT reason — a plain Error whose name is
    // "Error". An SDK that recognised aborts by `err.name === "AbortError"` would pass the first
    // and wrap the second into ServiceUnavailableError, i.e. work for the simple caller and fail
    // silently for the careful one. Rendering the CLASS NAME of each is what tells those apart:
    // "Error" here means the rejection came through untouched.
    el.querySelector("[data-role=sdk-abort-probe]").addEventListener("click", async () => {
      const attempt = async (signal) => {
        try { await host.service.get("fixture-svc", "slow", {}, { signal }); return "no-error" } catch (e) { return e.name }
      }
      const plain = new AbortController()
      plain.abort()
      const reasoned = new AbortController()
      reasoned.abort(new Error("superseded"))
      el.querySelector("[data-role=sdk-abort]").textContent =
        `plain=${await attempt(plain.signal)} reasoned=${await attempt(reasoned.signal)}`
    })

    // THE FILE PLANE, END TO END, IN THE ONE PLACE THE TRANSPORT IS REAL — write two files of
    // deliberately different KINDS in a single save, then read both back through the host and
    // render what came out.
    //
    // ONE SAVE, TWO SHAPES, BECAUSE THAT IS THE SHAPE A REAL ADDON HAS. A CAD addon emits a binary
    // 3MF beside a text README or G-code header, and the SDK routes each by its body's type: bytes
    // become a real multipart file part, a string stays inside the JSON `files` field. Sending them
    // together is what proves the two shapes coexist in ONE request with the array's order intact.
    //
    // THE READ-BACK IS THE ASSERTION, NOT THE SAVE. A save that silently mangled the bytes still
    // redirects and still reports "Saved." — the whole family of defects this exercises (CRLF
    // rewriting, UTF-8 re-encoding, a part swapped for its neighbour) is invisible from the write
    // side. Only fetching the bytes again can tell.
    //
    // NODE IDS COME FROM state.list(), because they have nowhere else to come from: files.save's
    // `data` is structurally empty today (the door answers a redirect, not JSON), so the states
    // endpoint — which relinks a save to the library nodes it produced, in `position` order — is
    // how a bundle finds what it just wrote. That is the same call a real addon's "open what I made
    // last time" is built on.
    el.querySelector("[data-role=sdk-roundtrip]").addEventListener("click", async () => {
      const out = el.querySelector("[data-role=sdk-roundtrip-result]")
      try {
        const result = await host.files.save({
          name: "sdk roundtrip",
          folderNodeId: q.get("parent") || "",
          files: [
            { name: q.get("bname"), contentType: "model/3mf", body: BYTES },
            { name: q.get("tname"), contentType: "text/plain", body: TEXT },
          ],
        })
        if (result.cancelled) { out.textContent = "Not saved."; return }

        const [ latest ] = await host.state.list()
        const bin = await host.files.read(latest.files[0].node_id)
        const txt = await host.files.read(latest.files[1].node_id)
        out.textContent = `bin=${hex(bin)} txt=${showEndings(new TextDecoder().decode(txt))}`
      } catch (e) {
        out.textContent = `${e.name}:${e.code}`
      }
    })

    // pickFile: A SELECTION OR null, AND THE TEST DRIVES BOTH. `extensions` is passed so the
    // client-side filter is exercised by something that runs — the Ruby side seeds a `.svg`
    // alongside the `.3mf` and asserts the picker offers only one of them.
    //
    // RENDERS "cancelled" FOR null RATHER THAN AN EMPTY STRING. Cancel and "chose something" must
    // stay distinguishable, and an empty textContent is exactly what a never-resolved promise also
    // looks like — a test asserting emptiness would pass on a picker that simply hung.
    el.querySelector("[data-role=sdk-pick]").addEventListener("click", async () => {
      const out = el.querySelector("[data-role=sdk-picked]")
      out.textContent = "opening"
      try {
        const picked = await host.files.pickFile({ extensions: [ ".3mf" ] })
        out.textContent = picked === null ? "cancelled" : `picked ${picked.kind} ${picked.path}`
      } catch (e) {
        out.textContent = `${e.name}:${e.code}`
      }
    })
  },
}
