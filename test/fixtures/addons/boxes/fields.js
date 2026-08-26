import { boxHelp, sectionId, clamp, rubyLines } from "./util.js"

// One param field. Ported from the tinkerex repo's app/views/tools/boxes/_field.html.erb. Every
// field is marked data-param="<name>" so preview.js / tray_sync.js / top_view.js / the save handler
// can all read the live values the same way, without any of them needing a <form> or native
// submission (this bundle POSTs JSON, not a form-encoded body).
//
// param: {name, type, default, help, choices, choice_labels, multiline} — the sidecar's own shape
// (sidecar/boxes/app.py's `_param`). prefillValues: the params hash of a saved box being duplicated,
// or null/{} for a fresh generator — presence of `param.name` as a KEY (not just a truthy value)
// distinguishes "no prefill, use the sidecar's default" from "prefilled with an empty string",
// exactly as the ERB's `values.present? && values.key?(pname)` did.
export function buildField(param, prefillValues) {
  const name = param.name
  const hasPrefill = !!(prefillValues && Object.prototype.hasOwnProperty.call(prefillValues, name))
  const value = hasPrefill ? prefillValues[name] : param.default

  const label = document.createElement("label")
  label.className = param.multiline ? "box-field box-field-multiline" : "box-field"

  const labelSpan = document.createElement("span")
  labelSpan.className = "box-field-label"
  labelSpan.append(name)

  const [ helpText, manualUrl ] = boxHelp(param.help)
  if (helpText) {
    const muted = document.createElement("span")
    muted.className = "muted"
    muted.textContent = ` — ${helpText}`
    labelSpan.append(muted)
  }
  if (manualUrl) {
    const link = document.createElement("a")
    link.className = "box-help"
    link.href = manualUrl
    link.target = "_blank"
    link.rel = "noopener noreferrer"
    link.title = "boxes.py manual"
    link.setAttribute("aria-label", `Manual for ${name}`)
    link.textContent = "?"
    labelSpan.append(link)
  }
  label.appendChild(labelSpan)
  label.appendChild(buildInput(param, name, value, hasPrefill))
  return label
}

function buildInput(param, name, value, hasPrefill) {
  let input

  if (param.choices?.length) {
    input = document.createElement("select")
    for (const choice of param.choices) {
      const key = String(choice)
      // `choice_labels` is the sidecar's {choice: description} map (sidecar/boxes/app.py's
      // `_choice_labels`, out of boxes.py's own `edges.getDescriptions()`). An edge param's choices
      // are single LETTERS — top_edge alone offers "e f F h c E S Š i k v L t G y Y" — so rendering
      // the value bare is sixteen options and nothing to choose between them. boxes.py's own web UI
      // never did that: `ArgparseEdgeType.html` composes each option as "{letter} {description}".
      //
      // ABSENT for an ordinary enum (FingerJoint_style, Lid_style), and absent from any sidecar
      // older than that key, and BOTH must fall through to the bare value — a bundle that assumed
      // the map was there would render "rectangular — undefined" on every deployment mid-rollout.
      //
      // The VALUE stays the bare letter. It is what boxes.py parses, and `paramValues` reads
      // `el.value`, so a label written into the value instead would look right and 422 every render.
      const label = param.choice_labels?.[key]
      const opt = new Option(label ? `${key} — ${label}` : key, key)
      if (key === String(value)) opt.selected = true
      input.add(opt)
    }
  } else if (param.type === "bool") {
    input = document.createElement("input")
    input.type = "checkbox"
    // A saved box's `params` blob may hold a REAL JSON boolean (this bundle's own saves) or the
    // string "true"/"false" (a state saved by the retired Rails form, which posted everything as a
    // plain form-encoded string) — both must display correctly.
    input.checked = value === true || value === "true"
  } else if (param.type === "float" || param.type === "int") {
    input = document.createElement("input")
    input.type = "number"
    input.step = "any"
    input.value = value ?? ""
  } else if (param.multiline) {
    // A <textarea>, built via the DOM API (createElement + a direct `.value =`) and never by
    // serializing HTML: an HTML PARSER swallows one newline directly after an opening <textarea>
    // tag, which is exactly the gotcha the retired ERB partial (_field.html.erb) had to work around
    // by having Rails' tag builder emit a spare leading newline to be eaten. Setting `.value` as a
    // DOM property never goes through an HTML parser at all, so that whole class of bug cannot recur
    // here — a genuine simplification the move to a bundle buys for free, not just a port.
    input = document.createElement("textarea")
    const text = String(value ?? "")
    const lines = rubyLines(text)
    input.rows = clamp(lines.length + 1, 4, 24)
    input.cols = clamp((Math.max(0, ...lines.map((l) => l.length)) || 0) + 6, 24, 72)
    input.wrap = "off"
    input.spellcheck = false
    input.value = text
    // Tells tray_sync.js to keep its hands off a layout loaded from a saved box.
    if (hasPrefill) input.dataset.prefilled = "true"
  } else {
    input = document.createElement("input")
    input.type = "text"
    input.value = value ?? ""
  }

  input.dataset.param = name
  return input
}

// Grouped param form, mirroring boxes.py's own web UI and the ERB _form.html.erb it replaces. EVERY
// group is a <details> — the generator's own settings and "Default Settings" start open, the
// advanced "Settings for <edge/part>" groups (Finger Joints, Lid, …) start closed — so any section
// can be folded away once done with it, not just the advanced ones. Advanced fields stay in the DOM
// either way, so they are always part of the submitted values.
//
// paramGroups: the sidecar's `param_groups` array. prefillValues: see buildField.
export function buildParamGroups(paramGroups, prefillValues) {
  const frag = document.createDocumentFragment()
  for (const group of paramGroups) {
    const details = document.createElement("details")
    details.className = group.advanced ? "param-group param-group-adv" : "param-group"
    details.id = sectionId(group.title, "param-group")
    details.dataset.boxsections = "section"
    details.open = !group.advanced

    const summary = document.createElement("summary")
    summary.className = "param-group-summary"
    const title = document.createElement("span")
    title.className = "param-group-title"
    title.textContent = group.title
    const count = document.createElement("span")
    count.className = "box-group-count"
    count.textContent = String(group.params.length)
    summary.append(title, count)
    details.appendChild(summary)

    const body = document.createElement("div")
    body.className = "box-params"
    for (const param of group.params) body.appendChild(buildField(param, prefillValues))
    details.appendChild(body)

    frag.appendChild(details)
  }
  return frag
}

// Every [data-param] descendant of `root`, keyed by name — the JSON body sent to the sidecar and to
// the save endpoint. Mirrors the ERB form's implicit contract (every field posts as params[<name>]
// regardless of which group it lives in) without needing an actual <form>.
export function paramValues(root) {
  const out = {}
  for (const el of root.querySelectorAll("[data-param]")) {
    out[el.dataset.param] = el.type === "checkbox" ? el.checked : el.value
  }
  return out
}
