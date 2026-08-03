// Trivial pinned dependency. Its only job is to be resolvable through the PER-REQUEST MERGED
// IMPORTMAP that Tools::AddonsController#merged_importmap draws (the host's own pins plus this
// addon's, as one map) — the subtlest part of the whole bundle pipeline, and the part a fixture is
// most likely to stop covering the day someone trims its manifest down to "just an entry". A
// fixture with no `pins` entry would still prove the shell mounts and the entry module loads, but it
// would silently drop coverage of bare-specifier resolution through the merged map — exactly the
// mechanism `generators`' own `import makerjs from "makerjs"` depends on in production.
export const label = "pinned-ok"
