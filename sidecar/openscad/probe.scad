// Build-time probe ONLY — not a catalog generator, never served to users.
// Deliberately shaped like this addon's real workload (a grid), and deliberately exercises the
// Customizer: three top-level LITERAL assignments with description comments, all before the first
// `{` character (OpenSCAD stops collecting parameters at that brace).
/* [Probe] */
// number of columns
cols = 4;
// number of rows
rows = 3;
// wall thickness in mm
wall = 2;

module plate() {
    for (i = [0:cols - 1], j = [0:rows - 1])
        translate([i * 10, j * 10, 0]) cube([8, 8, wall]);
}

plate();
