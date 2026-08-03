import { label } from "fixture-dep"

// Minimal addon bundle, owned by test/system/addon_bundle_test.rb. Its only job is to prove the
// HOST PIPELINE works end to end in a real browser: Tools::AddonsController#show renders the shell
// -> the Stimulus addon_controller.js dynamic-imports this file through the same-origin asset proxy
// (#asset) -> the browser resolves the bare "fixture-dep" specifier through the merged importmap
// (host pins + this addon's `pins`) -> mount(element, context) runs. Rendering the pinned module's
// own value into the DOM means a passing assertion proves the PIN resolved, not merely that this
// entry module loaded — a fixture that only asserted its own text could pass with `pins` broken.
export default {
  mount(el, ctx) {
    el.innerHTML = `<p data-role="fixture-output">${label}</p>`
  }
}
