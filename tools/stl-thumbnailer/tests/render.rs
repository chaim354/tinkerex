//! Integration tests for the STL -> PNG thumbnailer.
//!
//! Quality gate: the render must be a *real* shaded model, not a blank/noisy frame.

use image::GenericImageView;
use stl_thumbnailer::render_stl;

const TETRA: &[u8] = include_bytes!("fixtures/tetra.stl");
const CUBE_ASCII: &[u8] = include_bytes!("fixtures/cube_ascii.stl");

/// Decode PNG bytes; assert dimensions; return the RGBA pixels as a flat Vec.
fn decode(png: &[u8], w: u32, h: u32) -> Vec<[u8; 4]> {
    let img = image::load_from_memory(png).expect("output must be a decodable PNG");
    assert_eq!(img.dimensions(), (w, h), "PNG must be exactly w x h");
    img.to_rgba8().pixels().map(|p| p.0).collect()
}

/// Fraction of pixels that differ meaningfully from the most-common (background) color.
fn non_background_ratio(pixels: &[[u8; 4]]) -> f64 {
    use std::collections::HashMap;
    let mut counts: HashMap<[u8; 4], usize> = HashMap::new();
    for p in pixels {
        *counts.entry(*p).or_default() += 1;
    }
    let bg = *counts.iter().max_by_key(|(_, c)| **c).unwrap().0;
    let differ = pixels
        .iter()
        .filter(|p| {
            let dr = (p[0] as i32 - bg[0] as i32).abs();
            let dg = (p[1] as i32 - bg[1] as i32).abs();
            let db = (p[2] as i32 - bg[2] as i32).abs();
            dr + dg + db > 24
        })
        .count();
    differ as f64 / pixels.len() as f64
}

#[test]
fn renders_valid_png_of_exact_dimensions() {
    let png = render_stl(TETRA, 256, 256).expect("render should succeed");
    let _ = decode(&png, 256, 256);
}

#[test]
fn render_is_non_blank() {
    let png = render_stl(TETRA, 256, 256).expect("render should succeed");
    let pixels = decode(&png, 256, 256);
    let ratio = non_background_ratio(&pixels);
    assert!(
        ratio > 0.05,
        "model should occupy a meaningful fraction of the frame, got {ratio:.4}"
    );
}

#[test]
fn ascii_stl_path_works() {
    let png = render_stl(CUBE_ASCII, 200, 150).expect("ASCII STL should render");
    let pixels = decode(&png, 200, 150);
    let ratio = non_background_ratio(&pixels);
    assert!(
        ratio > 0.05,
        "ASCII cube should render a visible model, got {ratio:.4}"
    );
}

#[test]
fn non_square_dimensions_respected() {
    let png = render_stl(TETRA, 320, 180).expect("render should succeed");
    let _ = decode(&png, 320, 180);
}

#[test]
fn empty_mesh_does_not_panic_and_returns_valid_png() {
    // An empty (zero-triangle) binary STL: 80-byte header + u32(0) triangle count.
    let mut empty = vec![0u8; 80];
    empty.extend_from_slice(&0u32.to_le_bytes());
    let png = render_stl(&empty, 64, 64).expect("empty mesh should yield a blank-but-valid PNG");
    let pixels = decode(&png, 64, 64);
    // Blank: essentially all background, no crash.
    let ratio = non_background_ratio(&pixels);
    assert!(ratio < 0.01, "empty mesh should be ~blank, got {ratio:.4}");
}

#[test]
fn garbage_input_errors_not_panics() {
    let res = render_stl(b"not an stl file at all", 64, 64);
    assert!(res.is_err(), "garbage input should Err, not panic");
}

/// Build a tiny binary STL with ZERO face normals so the renderer must recompute
/// them from geometry — exercises the "missing/zero normals" requirement.
fn binary_stl_zero_normals(tris: &[[[f32; 3]; 3]]) -> Vec<u8> {
    let mut out = vec![0u8; 80];
    out.extend_from_slice(&(tris.len() as u32).to_le_bytes());
    for tri in tris {
        out.extend_from_slice(&[0u8; 12]); // zero normal
        for v in tri {
            for c in v {
                out.extend_from_slice(&c.to_le_bytes());
            }
        }
        out.extend_from_slice(&0u16.to_le_bytes()); // attribute byte count
    }
    out
}

/// Bounding box of the non-background pixels, as `(min_x, min_y, max_x, max_y)`.
/// `None` when the frame is blank.
fn ink_bbox(pixels: &[[u8; 4]], w: u32, h: u32) -> Option<(u32, u32, u32, u32)> {
    let bg = pixels[0]; // corner pixel: always background at these framings
    let (mut x0, mut y0, mut x1, mut y1) = (u32::MAX, u32::MAX, 0u32, 0u32);
    let mut any = false;
    for (i, p) in pixels.iter().enumerate() {
        let d = (p[0] as i32 - bg[0] as i32).abs()
            + (p[1] as i32 - bg[1] as i32).abs()
            + (p[2] as i32 - bg[2] as i32).abs();
        if d <= 24 {
            continue;
        }
        any = true;
        let (x, y) = (i as u32 % w, i as u32 / w);
        x0 = x0.min(x);
        y0 = y0.min(y);
        x1 = x1.max(x);
        y1 = y1.max(y);
    }
    let _ = h;
    any.then_some((x0, y0, x1, y1))
}

/// An upright box, much taller in Z than it is wide in X/Y.
fn tall_box(width: f32, height: f32) -> Vec<u8> {
    let (a, b, c) = (width, width, height);
    let v = |x: f32, y: f32, z: f32| [x, y, z];
    // 12 triangles, the 6 faces of an axis-aligned box from (0,0,0) to (a,b,c).
    let q = |p0: [f32; 3], p1: [f32; 3], p2: [f32; 3], p3: [f32; 3]| {
        [[p0, p1, p2], [p0, p2, p3]]
    };
    let mut tris: Vec<[[f32; 3]; 3]> = Vec::new();
    tris.extend(q(v(0., 0., 0.), v(a, 0., 0.), v(a, b, 0.), v(0., b, 0.))); // bottom
    tris.extend(q(v(0., 0., c), v(a, 0., c), v(a, b, c), v(0., b, c))); // top
    tris.extend(q(v(0., 0., 0.), v(a, 0., 0.), v(a, 0., c), v(0., 0., c)));
    tris.extend(q(v(0., b, 0.), v(a, b, 0.), v(a, b, c), v(0., b, c)));
    tris.extend(q(v(0., 0., 0.), v(0., b, 0.), v(0., b, c), v(0., 0., c)));
    tris.extend(q(v(a, 0., 0.), v(a, b, 0.), v(a, b, c), v(a, 0., c)));
    binary_stl_zero_normals(&tris)
}

/// THE ONLY TEST HERE THAT CAN SEE AN AXIS FLIP, and the reason every other one is blind to it is
/// that they all ask "is the frame non-blank?" — a question a model lying on its side answers just
/// as well as one standing up. STL is Z-UP by universal convention (see `auto_frame`), so a column
/// four times taller than it is wide must RENDER taller than it is wide.
///
/// Mutation-checked by restoring the old Y-up camera (`pitch.sin()` on the middle component plus
/// `Vec3::unit_y()` as the up vector): the box then renders 3.5x WIDER than tall and this goes red,
/// while the whole rest of this file stays green.
#[test]
fn tall_model_renders_taller_than_wide() {
    let png = render_stl(&tall_box(4.0, 16.0), 256, 256).expect("render should succeed");
    let pixels = decode(&png, 256, 256);
    let (x0, y0, x1, y1) = ink_bbox(&pixels, 256, 256).expect("the box must be visible");
    let (ink_w, ink_h) = (x1 - x0 + 1, y1 - y0 + 1);
    assert!(
        ink_h > ink_w * 2,
        "an upright 4x4x16 column rendered {ink_w}x{ink_h} — the camera is not Z-up"
    );
}

/// The other half of the same property, so a fix that merely swapped which axis is wrong cannot
/// pass. A slab WIDE in X/Y and thin in Z must render wider than it is tall.
#[test]
fn flat_model_renders_wider_than_tall() {
    let png = render_stl(&tall_box(16.0, 1.0), 256, 256).expect("render should succeed");
    let pixels = decode(&png, 256, 256);
    let (x0, y0, x1, y1) = ink_bbox(&pixels, 256, 256).expect("the slab must be visible");
    let (ink_w, ink_h) = (x1 - x0 + 1, y1 - y0 + 1);
    assert!(
        ink_w > ink_h,
        "a flat 16x16x1 slab rendered {ink_w}x{ink_h} — the camera is not Z-up"
    );
}

#[test]
fn zero_normals_are_recomputed_and_render() {
    // A simple quad (two triangles) in the XY plane, normals all zero.
    let tris = [
        [[0.0, 0.0, 0.0], [4.0, 0.0, 0.0], [4.0, 4.0, 0.0]],
        [[0.0, 0.0, 0.0], [4.0, 4.0, 0.0], [0.0, 4.0, 0.0]],
    ];
    let stl = binary_stl_zero_normals(&tris);
    let png = render_stl(&stl, 128, 128).expect("zero-normal STL should render");
    let pixels = decode(&png, 128, 128);
    let ratio = non_background_ratio(&pixels);
    assert!(
        ratio > 0.05,
        "recomputed-normal mesh should be visible + shaded, got {ratio:.4}"
    );
}

// ---- INK ON PAPER (2026-10-21) -------------------------------------------------------------------
//
// The web app multiplies every thumbnail onto a themed card, so the ground must be EXACTLY white —
// a shade off survives the multiply as a tinted square — and the model must be the palette's
// material. Both values are mirrored in Ruby (`Maker::Previews::Palette`) and in the CSS, and
// `test/services/maker/previews/palette_test.rb` holds the three spellings equal by PARSING the
// constants in src/lib.rs. These tests are the other half: they prove the constants are what the
// pixels actually come out as, which no Ruby test may assert (the CI runner bakes an older binary).

/// The material as the PNG should carry it at full light: `Palette::MATERIAL`, `#7f7b73`.
const MATERIAL_RGB: [u8; 3] = [0x7f, 0x7b, 0x73];

#[test]
fn background_is_pure_white() {
    let png = render_stl(TETRA, 128, 128).expect("render should succeed");
    let pixels = decode(&png, 128, 128);
    assert_eq!(
        pixels[0],
        [255, 255, 255, 255],
        "the corner must be exactly opaque white — it is multiplied onto the card"
    );
    assert_eq!(
        pixels[pixels.len() - 1],
        [255, 255, 255, 255],
        "and so must the opposite corner"
    );
}

/// The whole frame, not one corner: an empty mesh is nothing BUT ground, so every pixel of it is
/// the ground colour. Catches a ground that is white at the corner and tinted anywhere else.
#[test]
fn an_empty_mesh_is_white_paper_everywhere() {
    let mut empty = vec![0u8; 80];
    empty.extend_from_slice(&0u32.to_le_bytes());
    let png = render_stl(&empty, 32, 32).expect("empty mesh should yield a blank-but-valid PNG");
    let pixels = decode(&png, 32, 32);
    assert!(
        pixels.iter().all(|p| *p == [255, 255, 255, 255]),
        "an empty render must be pure white paper"
    );
}

/// THE BRIGHTEST FACE IS THE MATERIAL. The shader multiplies MATERIAL by an intensity of at most
/// 1.0, which it reaches only on a face square-on to the key light — so this builds exactly that
/// face: a square plate perpendicular to the light direction `(0.5, 0.6, 0.7)` in src/lib.rs.
///
/// A PLATE, NOT A CUBE: no face of an axis-aligned cube is square-on to that light (the best is
/// `|n . l| = 0.667`, intensity 0.76), so a cube's brightest face measures #615e57 and cannot show
/// whether MATERIAL itself is right. If the key light ever moves, move this plate with it — the
/// failure then says the plate no longer faces the light, not that the colour is wrong.
///
/// The plate's DOMINANT colour is asserted rather than its brightest pixel, because the
/// anti-aliased rim blends the material with the white ground and is brighter than the face.
#[test]
fn a_face_square_on_to_the_key_light_renders_the_material() {
    let l = normalize([0.5, 0.6, 0.7]);
    let u = normalize(cross(l, [0.0, 0.0, 1.0]));
    let v = cross(l, u);
    let corner = |su: f32, sv: f32| -> [f32; 3] {
        [
            10.0 * (su * u[0] + sv * v[0]),
            10.0 * (su * u[1] + sv * v[1]),
            10.0 * (su * u[2] + sv * v[2]),
        ]
    };
    let (a, b, c, d) = (
        corner(-1., -1.),
        corner(1., -1.),
        corner(1., 1.),
        corner(-1., 1.),
    );
    let png = render_stl(&binary_stl_zero_normals(&[[a, b, c], [a, c, d]]), 128, 128)
        .expect("render should succeed");
    let pixels = decode(&png, 128, 128);

    use std::collections::HashMap;
    let mut counts: HashMap<[u8; 4], usize> = HashMap::new();
    // The CORNER is the background, whatever colour it is: this test is about the material, and
    // the two ground tests above answer for the ground, so a ground mutation reddens them and not
    // this one.
    let ground = pixels[0];
    for p in pixels.iter().filter(|p| **p != ground) {
        *counts.entry(*p).or_default() += 1;
    }
    let (face, n) = counts
        .iter()
        .max_by_key(|(_, c)| **c)
        .expect("the plate must be visible");
    assert!(
        *n > 1000,
        "the plate should fill a good part of the frame, got {n} pixels"
    );
    for ch in 0..3 {
        assert!(
            (face[ch] as i32 - MATERIAL_RGB[ch] as i32).abs() <= 2,
            "a face square-on to the light rendered {face:?}; the material is {MATERIAL_RGB:?}"
        );
    }
}

fn normalize(p: [f32; 3]) -> [f32; 3] {
    let m = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt();
    [p[0] / m, p[1] / m, p[2] / m]
}

fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
