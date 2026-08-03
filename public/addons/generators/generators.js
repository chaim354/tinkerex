import materialTestGrid from "./material_test_grid.js"

// The Generators addon. Its only contract with the host is `mount(element, context)` — no Stimulus,
// no host framework. Adding a generator is a module + a line here, and no Ruby anywhere. The markup
// and class names below mirror the retired app/views/tools/generators/index.html.erb + its Stimulus
// controller so the existing .generator-* stylesheet (app/assets/stylesheets/application.css) still
// applies unchanged.
const REGISTRY = [materialTestGrid]

const build = (gen, values) => {
  try {
    return gen.generate(values)
  } catch (e) {
    const msg = String(e && e.message).replace(/[<&]/g, "")
    return `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="40"><text x="4" y="24" fill="#c00">${msg}</text></svg>`
  }
}

export default {
  mount(el, ctx) {
    el.innerHTML = `
      <div class="generator-editor">
        <aside class="generator-side">
          <label class="generator-picker-label">Generator
            <select data-role="picker"></select>
          </label>
          <div class="generator-params" data-role="fields"></div>
          <label class="generator-name-label">Name
            <input data-role="name" type="text" required placeholder="e.g. 3mm birch test">
          </label>
          <label class="generator-folder-label">Save into
            <select data-role="folder"></select>
          </label>
          <button type="button" data-role="save" class="generator-save">Save to library</button>
          <p class="muted" data-role="status"></p>
        </aside>
        <div class="generator-preview">
          <img data-role="preview" alt="live preview">
        </div>
      </div>`

    const $ = (role) => el.querySelector(`[data-role="${role}"]`)
    const current = () => REGISTRY.find((g) => g.key === $("picker").value) || REGISTRY[0]

    for (const gen of REGISTRY) {
      $("picker").add(new Option(gen.title, gen.key))
    }
    for (const [label, id] of ctx.folders) {
      const opt = new Option(label, id)
      if (id === ctx.defaultFolder) opt.selected = true
      $("folder").add(opt)
    }

    const values = () => Object.fromEntries(
      [...$("fields").querySelectorAll("[data-param]")].map((i) =>
        [i.dataset.param, i.type === "checkbox" ? i.checked : i.value])
    )

    const render = () => {
      const svg = build(current(), values())
      $("preview").src = `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
      return svg
    }

    const buildFields = () => {
      $("fields").innerHTML = ""
      for (const p of current().params) {
        const wrap = document.createElement("label")
        wrap.className = "generator-field"
        wrap.textContent = p.label || p.name
        const input = document.createElement("input")
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
        $("fields").appendChild(wrap)
      }
      render()
    }

    $("picker").addEventListener("change", buildFields)
    $("fields").addEventListener("input", render)

    $("save").addEventListener("click", async () => {
      const name = $("name").value.trim()
      if (!name) { $("status").textContent = "Name is required."; return }
      const svg = render()
      const body = new FormData()
      body.append("name", name)
      body.append("parent_node_id", $("folder").value)
      body.append("data", JSON.stringify({ generator: current().key, params: values() }))
      body.append("files", JSON.stringify([
        { name: `${name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.svg`,
          content_type: "image/svg+xml", body: svg },
      ]))
      const res = await fetch(ctx.saveUrl, {
        method: "POST", body, headers: { "X-CSRF-Token": ctx.csrfToken },
      })
      $("status").textContent = res.ok ? "Saved." : "Save failed."
    })

    buildFields()
  },
}
