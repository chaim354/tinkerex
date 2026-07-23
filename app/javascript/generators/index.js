// The client-side generator registry. Adding a generator = author a module (schema + geometry) and
// list it here. NO Ruby change — the Rails controller (Tools::GeneratorsController) is generator-
// agnostic. Each module is:
//   { key, title, description, params: [{name,label,type,default,min,max,step}], generate(values) }
// where generate(values) returns an SVG string.
import materialTestGrid from "generators/material_test_grid"

const REGISTRY = [materialTestGrid]

export const all = () => REGISTRY
export const find = (key) => REGISTRY.find((g) => g.key === key)
export default REGISTRY
