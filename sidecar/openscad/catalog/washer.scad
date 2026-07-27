/****************************************************
 Parametric Washer / Spacer (MakerWorld / OpenSCAD)
****************************************************/

/* [Basic] */

Shape = 0; // [0:Circle, 1:Triangle, 2:Square, 3:Polygon]

// Must be > Inner Diameter
Outer_Diameter = 25; // [1:0.1:200]
Height = 3; // [0.2:0.1:50]

// Sets Inner_Diameter automatically unless "Custom"
Screw_Preset = 0;    // [0:Custom, 1:M3, 2:M4, 3:M5, 4:M6, 5:M8]

// Only used when Screw Preset = Custom
Inner_Diameter = 8;  // [0:0.1:199]

// Only used when Shape = Polygon
Polygon_Sides = 6;   // [3:1:30]


/* [Advanced] */

// Adds extra clearance to the inner hole (mm)
Hole_Tolerance = 0.2; // [0:0.05:1]

// Chamfer (simple 45° style) on top and bottom edges
Chamfer = true;       // [true,false]
Chamfer_Size = 0.5;   // [0:0.1:5]

// Countersink on the top face
Countersink = false;          // [true,false]
Countersink_Top_Diameter = 12; // [0:0.1:200]
Countersink_Depth = 1.0;       // [0:0.1:20]


/* [Quality] */
$fn = 128; // [16:1:256]


// ---------- Derived parameters ----------

// Typical clearance holes (FDM-friendly defaults). Adjust as you like.
function preset_hole_d(p) =
    (p == 1) ? 3.2 :  // M3
    (p == 2) ? 4.3 :  // M4
    (p == 3) ? 5.3 :  // M5
    (p == 4) ? 6.4 :  // M6
    (p == 5) ? 8.4 :  // M8
              Inner_Diameter; // Custom

Inner_Hole_D = preset_hole_d(Screw_Preset) + Hole_Tolerance;


// ---------- Geometry helpers ----------
module regular_ngon(n, r) {
    polygon(points=[
        for (i = [0:n-1])
            [r*cos(360*i/n), r*sin(360*i/n)]
    ]);
}

module outer_profile(shape, od, n) {
    if (shape == 0) {
        circle(d = od);
    } else if (shape == 1) {
        regular_ngon(3, od/2);
    } else if (shape == 2) {
        square([od / sqrt(2), od / sqrt(2)], center = true); // diagonal = od
    } else {
        regular_ngon(max(3, n), od/2);
    }
}

// 2D chamfer via offset (shrinks the profile near top/bottom)
module chamfered_extrude_2d(profile_2d, h, c) {
    // If c == 0, just normal extrude
    if (c <= 0) {
        linear_extrude(height = h) children();
    } else {
        // Create a simple “bevel” by stacking 3 extrusions:
        // bottom bevel, straight middle, top bevel.
        // This is fast and robust in OpenSCAD.
        bottom_h = min(c, h/2);
        top_h    = min(c, h/2);
        mid_h    = max(0, h - bottom_h - top_h);

        // Bottom bevel: grow from slightly inset to full
        for (i = [0:1]) {
            // i=0 at very bottom (more inset), i=1 at top of bevel (less inset)
            t = i/1;
            z = t * bottom_h;
            translate([0,0,z])
                linear_extrude(height = (i==0)? bottom_h : 0)  // only extrude once at i=0
                    offset(delta = -(1 - t)*c) children();
        }

        // Middle straight section
        if (mid_h > 0)
            translate([0,0,bottom_h])
                linear_extrude(height = mid_h) children();

        // Top bevel: shrink towards top
        for (i = [0:1]) {
            t = i/1;
            z = bottom_h + mid_h + t * top_h;
            translate([0,0,z])
                linear_extrude(height = (i==0)? top_h : 0)
                    offset(delta = -t*c) children();
        }
    }
}

module washer(shape, od, hole_d, h, n, do_chamfer, chamfer_size, do_cs, cs_top_d, cs_depth) {
    assert(od > 0, "Outer_Diameter must be > 0");
    assert(h > 0, "Height must be > 0");
    assert(hole_d >= 0, "Inner hole must be >= 0");
    assert(od > hole_d, "Outer_Diameter must be > inner hole diameter");

    difference() {
        // Body (optionally chamfered)
        if (do_chamfer && chamfer_size > 0) {
            chamfered_extrude_2d(true, h, chamfer_size)
                difference() {
                    outer_profile(shape, od, n);
                    if (hole_d > 0) circle(d = hole_d);
                }
        } else {
            linear_extrude(height = h)
                difference() {
                    outer_profile(shape, od, n);
                    if (hole_d > 0) circle(d = hole_d);
                }
        }

        // Countersink (top face)
        if (do_cs && cs_top_d > hole_d && cs_depth > 0) {
            // subtract a conical frustum from the top
            translate([0,0,h - min(cs_depth, h)])
                cylinder(
                    h = min(cs_depth, h),
                    d1 = cs_top_d,
                    d2 = hole_d,
                    center = false
                );
        }
    }
}


// ---------- Build ----------
washer(
    Shape,
    Outer_Diameter,
    Inner_Hole_D,
    Height,
    Polygon_Sides,
    Chamfer,
    Chamfer_Size,
    Countersink,
    Countersink_Top_Diameter,
    Countersink_Depth
);
