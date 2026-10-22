module Maker
  module Previews
    # THE COLOURS EVERY SERVER-RENDERED THUMBNAIL IS DRAWN IN: INK ON PAPER (2026-10-21).
    #
    # EVERY RENDER PAINTS A PURE-WHITE GROUND, AND "PURE" IS THE LOAD-BEARING WORD. The browser does
    # not show a thumbnail as-is: it MULTIPLIES it onto a themed card (`--thumb-stage`,
    # design-system.md rule 5), so white becomes the card and ink stays ink in both themes. That is
    # also what lets a picture we did not draw — LightBurn's own embedded thumbnail, a PDF page, a
    # slicer's — sit beside ours on the same ground without editing a stored pixel. A ground a shade
    # off white survives the multiply as a visible tinted square on every card, which is the dark
    # `#202228` STL tile and F3D's `#333333` this module replaced.
    #
    # INK IS THE PALETTE'S, NEVER A COOL BLUE-BLACK. It equals Paper's `--fg` (application.css's
    # first `:root` block); the text thumbnail drew `#1c2230` before, a navy from another product.
    #
    # MATERIAL IS THE ONE MESH COLOUR, for the STL thumbnailer, F3D's fallback and the 3D viewer's
    # default (`--model-material`). It is not redefined per theme because it does not need to be: it
    # clears 3:1 on all four grounds a mesh meets — the viewer's `--raised` in Paper (3.44:1) and
    # Graphite (3.61:1), and the card in Paper (4.18:1) and Graphite (3.58:1). A colour that read on
    # only one of them would make a live theme switch repaint the model, not just the background.
    #
    # THE CRATE CANNOT READ THIS FILE. `tools/stl-thumbnailer/src/lib.rs` spells PAPER and MATERIAL
    # as its own `BG` / `MATERIAL` constants, and `palette_test.rb` holds the two spellings — and
    # these and the CSS tokens — equal, STATICALLY: the CI runner image bakes the binary at image
    # build time, so no Ruby test may assert what an STL render's pixels are.
    #
    # CHANGING A VALUE HERE IS A RE-RENDER. Bump the `THUMBNAIL_REVISION` of every renderer that
    # paints it (§14h) — `Stl` (and `ThreeMf` with it), `Mesh`, `TextThumb` — or the library keeps
    # the old picture forever; and a MATERIAL change also needs the crate rebuilt (measure-view.md:
    # ship both or neither).
    module Palette
      PAPER = "#ffffff".freeze
      INK = "#1b1c19".freeze
      MATERIAL = "#7f7b73".freeze
    end
  end
end
