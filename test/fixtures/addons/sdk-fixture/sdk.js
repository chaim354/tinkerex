import { host, WouldReplaceError } from "@maker/addon-sdk"

// A bundle written the way docs/addon-api-v1.md tells an author to write one: it imports the SDK
// and touches `ctx` for nothing. Its job is to prove, in a real browser, that (a) the host pin
// resolves inside an addon's merged importmap, (b) initHost ran before this module was imported,
// (c) capabilities() answers the server's own map, (d) files.save absorbs BOTH ARMS of the 409
// overwrite dance every bundle used to copy by hand — accepting re-POSTs with overwrite=1,
// declining writes nothing — which is why `decline` joins the query string below, (e) the service
// plane — its transport, its URL builder and its abort handling — behaves in a real browser, which
// for the transport is the ONLY place it can be observed at all (see ART below), and (f) the
// state-revision surface (`stateId` on save, state.revisions, host.launch) reaches the host with
// its id intact.
//
// The destination, the filename and the overwrite answer come from the QUERY STRING so the Ruby
// test can point the fixture at whatever project folder it just built and drive either arm of the
// 409, rather than the fixture hard-coding library state or one answer.

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
      <p data-role="sdk-picked"></p>
      <input data-role="sdk-state-id">
      <button data-role="sdk-save-revision">Save revision</button>
      <p data-role="sdk-revision-out"></p>
      <button data-role="sdk-revisions">Load revisions</button>
      <p data-role="sdk-revisions-out"></p>
      <button data-role="sdk-revisions-probe">Probe state id guards</button>
      <p data-role="sdk-revisions-guards"></p>
      <p data-role="sdk-launch"></p>`

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
          // THE ANSWER COMES FROM THE QUERY STRING, like `parent` and `fname` above, because the
          // SDK does two DIFFERENT things with it and only a Ruby-side switch can drive both: TRUE
          // re-POSTs with overwrite=1, FALSE returns `{cancelled: true}` and writes nothing. A real
          // bundle would call window.confirm; the fixture answers deterministically so no dialog is
          // involved. TRUE stays the default — declining is the arm a test has to ASK for.
          onReplace: (files) => {
            status.dataset.replaced = files.map((f) => `${f.name}@${f.folder}`).join(",")
            return q.get("decline") !== "1"
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

    // ---- state revisions (host level 3) ------------------------------------------------------

    // The id the three controls below operate on. An <input> rather than a query parameter because
    // the Ruby side only learns the id AFTER driving a real save through this same page, so there is
    // no URL left to put it in. Filling a field keeps the save and the revision on ONE mount; a
    // second `visit` is a hard browser load that tears the whole JS runtime down and rebuilds it
    // (the Turbo test at the foot of addon_sdk_test.rb spells that out).
    const stateIdInput = el.querySelector("[data-role=sdk-state-id]")

    // REVISING IS THE SAME SAVE PLUS ONE FIELD. Deliberately writes a DIFFERENT filename from the
    // first save: whether a revision may replace its OWN file is Task 3's collision exemption and is
    // pinned server-side, while what this control exists to prove is narrower and can only be proved
    // here — that `stateId` survives the browser's own multipart serializer and reaches the door.
    //
    // A NUMBER HERE AND A STRING IN `Load revisions` BELOW, ON PURPOSE: the SDK accepts both
    // spellings of an id (state.list() answers integers, an <input> answers a string), so driving
    // one through each door is what stops either coercion from rotting unobserved.
    el.querySelector("[data-role=sdk-save-revision]").addEventListener("click", async () => {
      const out = el.querySelector("[data-role=sdk-revision-out]")
      try {
        const result = await host.files.save({
          name: "sdk fixture revised",
          folderNodeId: q.get("parent") || "",
          data: { n: 2 },
          stateId: Number(stateIdInput.value),
          files: [ { name: q.get("rname") || "revised.txt", contentType: "text/plain", body: "v2" } ],
        })
        out.textContent = result.cancelled ? "Not saved." : "Saved."
      } catch (e) {
        out.textContent = `${e.name}:${e.code}`
      }
    })

    // THE HISTORY, NEWEST FIRST, WITH EACH SNAPSHOT'S OWN PARAMS. Rendering `data` as well as the
    // revision number is what gives the assertion teeth: a `revisions` that returned the CURRENT
    // data for every row — the shape a naive implementation reading `state.data` would produce —
    // renders identical params twice and fails, while a bare "v2,v1" would pass it happily.
    el.querySelector("[data-role=sdk-revisions]").addEventListener("click", async () => {
      const out = el.querySelector("[data-role=sdk-revisions-out]")
      try {
        const rows = await host.state.revisions(stateIdInput.value)
        out.textContent = rows.map((r) => `v${r.revision}:${r.data.n ?? "-"}`).join(",")
      } catch (e) {
        out.textContent = `${e.name}:${e.code}`
      }
    })

    // THE ID GUARD, AT BOTH DOORS, WHICH IS THE ONLY PLACE HALF OF IT IS OBSERVABLE. ".", ".." and
    // "" are the only strings encodeURIComponent leaves untouched, so a revisions URL built from one
    // is normalized BY THE BROWSER before the request is sent — the server's own route never sees
    // it and the call misroutes silently. That half can only be caught in a real browser.
    //
    // THE ARRAY IS THE OTHER HALF AND IT IS NOT A PATH PROBLEM AT ALL — it is the one an ordinary
    // request test cannot see either, because the laundering happens in JS. `String([n, n])` is
    // "n,n", which the server's String-or-Integer allowlist cannot refuse (JS already flattened it
    // to a String) and which ActiveRecord's integer cast turns straight back into n.
    //
    // IT IS BUILT FROM THE ID IN THE INPUT — a REAL row — rather than a made-up [1, 2], and that is
    // the whole difference between this probe and one that proves nothing. §14c records the shape:
    // a traversal test that could only ever reach a 404 passed under mutation, because "refused"
    // and "not found" both produce one. Aimed at a row that exists, removing the guard makes this
    // read answer `no-error` — a history nobody asked for — and makes the write below append a
    // revision to a design nobody named.
    //
    // ON A GREEN RUN THIS WRITES NOTHING. `save` throws at the id before it reaches `_post`, so no
    // request leaves the browser and no file is created; the library write described above happens
    // ONLY while the guard is mutated out, which is exactly what makes the mutation legible.
    el.querySelector("[data-role=sdk-revisions-probe]").addEventListener("click", async () => {
      const attempt = async (fn) => {
        try { await fn(); return "no-error" } catch (e) { return `${e.name}:${e.code}` }
      }
      const read = async (id) => attempt(() => host.state.revisions(id))
      const laundered = [ stateIdInput.value, stateIdInput.value ]
      const write = await attempt(() => host.files.save({
        name: "guard probe", folderNodeId: q.get("parent") || "", stateId: laundered,
        files: [ { name: "guard-probe.txt", contentType: "text/plain", body: "x" } ],
      }))
      el.querySelector("[data-role=sdk-revisions-guards]").textContent =
        `empty=${await read("")} dot=${await read(".")} dotdot=${await read("..")} ` +
        `array=${await read(laundered)} write=${write}`
    })

    // THE DEEP-LINK HINT, READ STRAIGHT THROUGH FROM ctx. No `?.` on `host.launch`, deliberately:
    // the host's contract is that `launch` is ALWAYS an object with a `stateId` key that may be null
    // (the same argument capabilities() makes for every value being a real boolean), so an optional
    // chain here would quietly render "launch:none" for a host that stopped sending it at all —
    // exactly the case a bundle cannot tell apart from "nothing to open".
    //
    // AND `old:` IS THAT VERY CASE, SIMULATED, BECAUSE THIS SERVER CAN NO LONGER PRODUCE IT. Every
    // ctx it serves now carries `launch`, so the compatibility default inside the getter —
    // `{stateId: null, ...}` — is invisible to any assertion driven through a real page: drop it and
    // the spread still finds the server's own key, and every test stays green over a getter that
    // would answer `undefined` to the level-2 hosts a published bundle still has to run against.
    // Calling the getter with a synthetic `_ctx` is the only vantage point left. It reaches through
    // the prototype ON PURPOSE rather than exporting the Host class for a test: the SDK's whole
    // premise is that a bundle touches `host` and nothing else, and widening the public API to pin
    // a private default would cost more than the awkwardness of this line.
    const launchGetter =
      Object.getOwnPropertyDescriptor(Object.getPrototypeOf(host), "launch").get
    const oldHostLaunch = launchGetter.call({ _ctx: {} })   // a level-2 ctx: no `launch` key at all

    el.querySelector("[data-role=sdk-launch]").textContent =
      `launch:${host.launch.stateId ?? "none"} old:${JSON.stringify(oldHostLaunch)}`
  },
}
