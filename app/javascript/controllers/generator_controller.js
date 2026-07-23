import { Controller } from "@hotwired/stimulus"
import * as registry from "generators/index"

// The generator harness. Builds the picker + param form from the JS registry, previews the active
// module's SVG live (data-URL <img> — SVG in <img> can't run scripts, so user text in labels is
// safe), and keeps the hidden `generator`/`svg` fields current for the Rails form POST. Reopen:
// data-generator-reopen-value = {generator, params} prefills generator + fields.
export default class extends Controller {
  static targets = ["picker", "fields", "preview", "generatorField", "svgField"]
  static values = { reopen: Object }

  connect() {
    this.populatePicker()
    const reopenKey = this.reopenValue && this.reopenValue.generator
    if (reopenKey && registry.find(reopenKey)) this.pickerTarget.value = reopenKey
    this.selectGenerator()
    if (reopenKey) this.prefill(this.reopenValue.params || {})
  }

  populatePicker() {
    this.pickerTarget.innerHTML = ""
    for (const gen of registry.all()) {
      const opt = document.createElement("option")
      opt.value = gen.key
      opt.textContent = gen.title
      this.pickerTarget.appendChild(opt)
    }
  }

  selectGenerator() {
    const gen = this.currentGenerator()
    this.generatorFieldTarget.value = gen.key
    this.buildFields(gen)
    this.render()
  }

  buildFields(gen) {
    this.fieldsTarget.innerHTML = ""
    for (const p of gen.params) {
      const wrap = document.createElement("label")
      wrap.className = "generator-field"
      wrap.textContent = p.label || p.name
      const input = document.createElement("input")
      input.name = `params[${p.name}]`
      input.dataset.param = p.name
      if (p.type === "bool") {
        input.type = "checkbox"
        input.checked = !!p.default
      } else if (p.type === "text") {
        input.type = "text"
        input.value = p.default ?? ""
      } else {
        input.type = "number"
        if (p.min != null) input.min = p.min
        if (p.max != null) input.max = p.max
        input.step = p.step ?? (p.type === "int" ? 1 : "any")
        input.value = p.default ?? 0
      }
      wrap.appendChild(input)
      this.fieldsTarget.appendChild(wrap)
    }
  }

  values() {
    const out = {}
    for (const el of this.fieldsTarget.querySelectorAll("[data-param]")) {
      out[el.dataset.param] = el.type === "checkbox" ? el.checked : el.value
    }
    return out
  }

  prefill(params) {
    for (const el of this.fieldsTarget.querySelectorAll("[data-param]")) {
      const v = params[el.dataset.param]
      if (v == null) continue
      if (el.type === "checkbox") el.checked = !!v
      else el.value = v
    }
    this.render()
  }

  render() {
    const gen = this.currentGenerator()
    let svg
    try {
      svg = gen.generate(this.values())
    } catch (e) {
      const msg = String(e && e.message).replace(/[<&]/g, "")
      svg = `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="40"><text x="4" y="24" fill="#c00">${msg}</text></svg>`
    }
    this.svgFieldTarget.value = svg
    this.previewTarget.src = `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
  }

  currentGenerator() {
    return registry.find(this.pickerTarget.value) || registry.all()[0]
  }
}
