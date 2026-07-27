// Perforated plate — a simple parametric grid plate with an optional hole per cell.
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Tinkerex. FIRST-PARTY: written for this repo, not vendored from anywhere,
// so it carries no third-party licensing question at all.
//
// Its job is to keep the catalog endpoints (/generators, /source/<key>) genuinely exercised
// before Task 6 vendors the audited third-party generators alongside it. It is also shaped to
// exercise the Customizer's real surface: every parameter below is a top-level LITERAL assignment
// declared before the first `{` in the file, which is exactly where OpenSCAD stops collecting.

/* [Plate] */
// number of columns
cols = 4; // [1:20]
// number of rows
rows = 3; // [1:20]
// cell pitch in mm
pitch = 10;
// plate thickness in mm
thickness = 2;

/* [Holes] */
// drill a hole through each cell
holes = true;
// hole diameter in mm
hole_dia = 3;

module plate() {
    difference() {
        cube([cols * pitch, rows * pitch, thickness]);
        if (holes)
            for (i = [0 : cols - 1], j = [0 : rows - 1])
                translate([(i + 0.5) * pitch, (j + 0.5) * pitch, -1])
                    cylinder(h = thickness + 2, d = hole_dia, $fn = 32);
    }
}

plate();
