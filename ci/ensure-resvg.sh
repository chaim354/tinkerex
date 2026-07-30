#!/usr/bin/env bash
# Ensure `resvg` is on PATH for the preview tests (SVG/DXF/LightBurn → PNG).
#
# NON-FATAL BY DESIGN, but LOUD when it degrades. The preview tests branch on
# Maker::Previews::SvgRasterizer.available?, so a box without resvg still PASSES — it just renders
# `unsupported` and never exercises the real PNG path. The previous version of this step was
# `cargo install resvg || true`, which turned that into a silent downgrade: green, about less.
# That is the same shape as brakeman's exit 3 — a gate that is not a gate.
#
# Order is cheapest-first. brew has a bottled resvg (0.47.0, MPL-2.0); `cargo install` builds it
# from source and takes minutes on a cold box.
set -uo pipefail

if command -v resvg >/dev/null 2>&1; then
  echo "resvg: already present at $(command -v resvg)"
  exit 0
fi

if command -v brew >/dev/null 2>&1 && brew install resvg; then
  echo "resvg: installed via brew ($(command -v resvg))"
  exit 0
fi

if command -v cargo >/dev/null 2>&1 && cargo install resvg --version 0.47.0; then
  echo "$HOME/.cargo/bin" >> "${GITHUB_PATH:-/dev/null}"
  echo "resvg: installed via cargo"
  exit 0
fi

{
  echo "### ⚠️ resvg unavailable — preview coverage DEGRADED"
  echo
  echo "\`Maker::Previews::SvgRasterizer.available?\` is false on this runner, so the SVG, DXF and"
  echo "LightBurn preview tests render \`unsupported\` instead of exercising the real PNG path."
  echo
  echo "**This job is still green. It is green about less than you think.** Install resvg on the"
  echo "runner (\`brew install resvg\`) to restore the coverage."
} >> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"

exit 0
