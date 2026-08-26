import re

import app as appmod
from app import app


def client():
    app.config.update(TESTING=True)
    return app.test_client()


def test_up():
    r = client().get("/up")
    assert r.status_code == 200
    assert r.data == b"ok"


def test_generators_shape():
    data = client().get("/generators").get_json()
    assert isinstance(data, list) and len(data) > 50
    g = next(x for x in data if x["key"] == "ABox")
    assert g["title"] and g["group"] == "Box"  # real boxes.py ui_group, not a hard-coded label
    groups = g["param_groups"]
    assert isinstance(groups, list) and groups
    all_names = {p["name"] for grp in groups for p in grp["params"]}
    assert {"x", "y", "h"} <= all_names
    xp = next(p for grp in groups for p in grp["params"] if p["name"] == "x")
    assert xp["type"] in ("float", "int") and xp["default"] is not None
    # transport/internal params stay hidden
    assert "format" not in all_names and "output" not in all_names
    # the advanced edge/part groups are now SURFACED (previously dropped) and flagged advanced
    fj = next(grp for grp in groups if grp["title"] == "Settings for Finger Joints")
    assert fj["advanced"] is True
    assert any(p["name"] == "FingerJoint_style" for p in fj["params"])
    # the generator's own settings are a non-advanced group
    assert any(not grp["advanced"] for grp in groups)


def test_generate_returns_svg():
    r = client().post("/generate", json={"generator": "ABox", "params": {"x": 80, "y": 40, "h": 30}})
    assert r.status_code == 200
    assert r.mimetype == "image/svg+xml"
    assert r.data[:5] == b"<?xml" or b"<svg" in r.data[:400]


def test_generate_bad_generator_is_404():
    assert client().post("/generate", json={"generator": "NopeNope", "params": {}}).status_code == 404


def test_generate_bad_params_is_422():
    r = client().post("/generate", json={"generator": "ABox", "params": {"x": "not-a-number"}})
    assert r.status_code == 422


def _params(generator):
    data = client().get("/generators").get_json()
    g = next(x for x in data if x["key"] == generator)
    return {p["name"]: p for grp in g["param_groups"] for p in grp["params"]}


def test_multiline_params_are_flagged_so_the_form_uses_a_textarea():
    # boxes.py's own web UI picks a <textarea> for a str param whose default carries a newline; we
    # report that as `multiline` and the form does the same. It is not cosmetic: an <input type=text>
    # strips line breaks (HTML value sanitization), so these arrived here as a single line.
    assert _params("TrayLayout")["layout"]["multiline"] is True
    assert _params("Desksign")["label"]["multiline"] is True
    assert _params("FrontPanel")["layout"]["multiline"] is True
    assert _params("NightLightBox")["BackExtraHoles"]["multiline"] is True
    # sx/sy report type "str" too but their argparse type is argparseSections, not str -> single-line
    assert _params("TrayLayout")["sx"]["multiline"] is False
    assert _params("ABox")["x"]["multiline"] is False


def test_blank_layout_default_is_seeded_with_a_layout_that_actually_renders():
    # boxes.py defaults TrayLayout's layout to "\n" purely to trip its textarea rule. Handed to the
    # user that way it fails either as "Need more than one wall in x direction" (sent verbatim) or
    # "traylayout requires --layout, --input, or implementation of generate_layout" (sent empty), so
    # we seed it from boxes.py's own TrayLayoutFile instead.
    layout = _params("TrayLayout")["layout"]["default"]
    assert layout.strip(), "a blank layout is exactly what the seeding exists to prevent"
    assert "+-+" in layout and "mm" in layout
    assert len(layout.splitlines()) > 4

    # The real check: what we advertise must survive a round-trip back through /generate untouched.
    r = client().post("/generate", json={"generator": "TrayLayout", "params": {"layout": layout}})
    assert r.status_code == 200, r.data
    assert r.mimetype == "image/svg+xml"


def test_every_advertised_multiline_default_round_trips_to_svg():
    for generator in ("TrayLayout", "GridfinityTrayLayout", "FrontPanel", "NightLightBox", "Desksign"):
        multiline = {n: p["default"] for n, p in _params(generator).items() if p["multiline"]}
        assert multiline, generator
        r = client().post("/generate", json={"generator": generator, "params": multiline})
        assert r.status_code == 200, (generator, r.data[:200])
        assert r.mimetype == "image/svg+xml", generator


def test_seeding_does_not_break_a_generator_that_falls_back_on_an_empty_layout():
    # GridfinityTrayLayout has a generate_layout() fallback, so an EMPTY layout is legitimate for it
    # and was the only reason it worked before this — the form used to strip the "\n" to "". Seeding
    # must not take that path away, or a user who clears the box gets an error instead of a default.
    r = client().post("/generate", json={"generator": "GridfinityTrayLayout", "params": {"layout": ""}})
    assert r.status_code == 200 and r.mimetype == "image/svg+xml"


def test_every_generator_renders_with_its_own_advertised_defaults():
    """Hand /generators' own answer straight back to /generate and require SVG from every one.

    THE FAILURE THIS EXISTS FOR: three generators 422'd for every user, forever, because the argv we
    built did not match the argparser we built the schema FROM. A per-generator test would never have
    found it — the broken ones were CompartmentBox, TypeTray and TrayLayoutFile, none of which anyone
    would have thought to single out. The only honest check is all of them.
    """
    c = client()
    gens = c.get("/generators").get_json()
    assert len(gens) > 150, "the whole point is breadth; a truncated list makes this vacuous"
    broken = []
    for g in gens:
        params = {p["name"]: p["default"] for grp in g["param_groups"] for p in grp["params"]
                  if p["default"] is not None}
        r = c.post("/generate", json={"generator": g["key"], "params": params})
        body = r.data
        # A COMPLETE drawing, not merely a 200. Checking status+mimetype alone passed `Edges`, which
        # answered 200 image/svg+xml with a ZERO-BYTE body (its render() only prints to stdout) —
        # which would have put an empty .svg in the user's library on save.
        if not (r.status_code == 200 and r.mimetype == "image/svg+xml" and len(body) > 500
                and (body[:5] == b"<?xml" or b"<svg" in body[:600]) and b"</svg>" in body[-400:]):
            broken.append((g["key"], r.status_code, len(body), str(r.get_json())[:120]))
    assert not broken, f"{len(broken)} generator(s) cannot render their own defaults: {broken}"


def test_a_param_whose_dest_differs_from_its_flag_reaches_the_generator():
    """FlexBox3 declares `--c` with dest `d`. Building the flag as "--" + dest sent `--d`, which
    argparse ABBREVIATION-matched to the only `--d*` option it has — `--debug` — so the user's value
    was swallowed by a plumbing flag and the box rendered at the default.

    This one returned 200 the whole time. It is the reason the fix is "use the option string argparse
    registered", not "special-case the two generators that 422'd".
    """
    c = client()
    a = c.post("/generate", json={"generator": "FlexBox3", "params": {"d": 1.0}})
    b = c.post("/generate", json={"generator": "FlexBox3", "params": {"d": 6.0}})
    assert a.status_code == 200 and b.status_code == 200, (a.get_json(), b.get_json())

    # COMPARE THE DRAWING, NOT THE PAYLOAD. boxes.py records the argv it was handed into the SVG
    # (`<dc:source>boxes FlexBox3 --format svg --d 6.0` and a "Command line:" comment), so the raw
    # bytes differ even when the value changed nothing at all. Asserting `a.data != b.data` PASSES
    # against the bug — verified: with --d swallowed by --debug the two renders were byte-identical
    # in length (45429) and differed on exactly those two metadata lines.
    geometry = lambda svg: re.sub(rb"boxes FlexBox3[^<\n]*", b"", svg)  # noqa: E731
    assert geometry(a.data) != geometry(b.data), (
        "d=1 and d=6 drew the same box -> the value never reached the generator"
    )


def test_argv_emits_the_option_string_argparse_registered_not_the_dest():
    """The wire format, asserted directly — the round-trip above can only see a value that CHANGES
    the drawing, and 'silently sent the wrong flag' is precisely the bug that hides from that.

    boxes.py declares these five params with a dest that is not its option string; every other param
    across the 185 generators has dest == flag, which is why "--" + dest looked right.
    """
    cases = {
        "FlexBox3": {"d": "--c"},
        "CompartmentBox": {"margin_vertical": "--margin_t", "margin_side": "--margin_s"},
        "TypeTray": {"gh": "--gripheight", "gw": "--gripwidth"},
    }
    for generator, expected in cases.items():
        box = appmod._all_generators()[generator]()
        argv = appmod._argv(box, {dest: 1 for dest in expected})
        for dest, flag in expected.items():
            assert flag in argv, f"{generator}.{dest} should be sent as {flag}; got {argv}"
            assert f"--{dest}" not in argv, f"{generator} still sends --{dest}; got {argv}"


def test_format_svg_is_only_sent_to_a_parser_that_has_it():
    """`--format svg` was prepended unconditionally. TrayLayoutFile is the one generator whose parser
    is just [-h] [--sx] [--sy] [--output], so it 422'd on an argument the sidecar itself added."""
    box = appmod._all_generators()["TrayLayoutFile"]()
    assert "--format" not in appmod._argv(box, {"sx": "50*3"})
    assert "--format" in appmod._argv(appmod._all_generators()["ABox"](), {"x": 60})


def test_file_params_are_not_advertised_as_form_fields():
    """A FileType param names a path on the SIDECAR's filesystem, which a browser client can never
    put a file at. Rendering it as a text input gives the user a field that cannot work and hands
    them a server-side open() primitive. Mirror the RULE (drop FileType) rather than naming the param,
    the same way `_multiline` mirrors boxes.py's textarea rule.

    In this pinned boxes.py the one instance is upstream-broken anyway: typetray.py:119 declares
    `type=argparse.FileType('r')` (argparse hands the generator an open file) and :247 does
    `Path(self.label_file).open()` (which needs a path), so ANY non-empty value raises TypeError and
    the empty default makes argparse try to open ''.
    """
    assert "label_file" not in _params("TypeTray")


def test_generators_upstream_marks_as_not_for_a_web_ui_are_not_offered():
    """boxes.py sets `webinterface = False` on the generators its OWN web UI excludes. Mirror that
    rule rather than keeping a list of names, exactly as `_multiline` mirrors its textarea rule — a
    boxes.py bump then can't silently outgrow us, which is the drift that caused this whole bug.

    All four are wrong here for reasons independently confirmed:
      * Edges          — render() only prints to stdout; answered 200 with a ZERO-BYTE body.
      * TrayLayoutFile — emits an ASCII layout ('+-+-+-+'), not SVG; its parser has no --format at
        all. It is step 1 of the two-step CLI flow, and this sidecar already runs it INTERNALLY to
        seed TrayLayout's textarea, so a user gains nothing from it.
      * JigsawPuzzle   — upstream's own docstring says "Still alpha".
      * Lamp           — no docstring (the tile would be titled from the bare key), 484 KB render.

    Hidden at the API boundary ONLY: `_all_generators()` still returns them, which is what the
    seeding depends on — `test_blank_layout_default_is_seeded...` is what proves that still works.
    """
    c = client()
    offered = {g["key"] for g in c.get("/generators").get_json()}
    for key in ("Edges", "TrayLayoutFile", "JigsawPuzzle", "Lamp"):
        assert key not in offered, f"{key} is marked webinterface=False upstream"
        assert c.post("/generate", json={"generator": key, "params": {}}).status_code == 404, key
    assert "ABox" in offered, "the rule must not hide ordinary generators"


def test_invalid_parameters_422_names_the_offending_parameter():
    """`except SystemExit` used to collapse every argparse failure into "invalid parameters",
    discarding the one line that says which param and why. Rails passes the sidecar's message
    straight to the UI, so that discarded line is the difference between a diagnosable error and a
    shrug. The usage dump and the program name (a gunicorn path) stay out of it.
    """
    r = client().post("/generate", json={"generator": "ABox", "params": {"x": "not-a-number"}})
    assert r.status_code == 422
    msg = r.get_json()["error"]
    assert "x" in msg and "not-a-number" in msg, msg
    assert "usage:" not in msg, f"the usage dump is noise, not a message: {msg}"


def test_an_unknown_parameter_is_refused_by_name():
    """Silently dropping a param the parser does not have is how a boxes.py upgrade would quietly
    change everyone's saved boxes. Refuse it, and say which one."""
    r = client().post("/generate", json={"generator": "ABox", "params": {"nonesuch": 1}})
    assert r.status_code == 422
    assert "nonesuch" in r.get_json()["error"]


def test_sample_serves_a_thumbnail_and_guards_the_name(tmp_path):
    import app as appmod
    (tmp_path / "ABox-thumb.jpg").write_bytes(b"\xff\xd8\xff\xe0JFIFdata")
    old = appmod.SAMPLES_DIR
    appmod.SAMPLES_DIR = str(tmp_path)
    try:
        c = client()
        r = c.get("/sample/ABox")
        assert r.status_code == 200 and r.mimetype == "image/jpeg"
        assert c.get("/sample/Missing").status_code == 404   # no such sample -> 404 (tile falls back)
        assert c.get("/sample/bad.name").status_code == 404  # non-alnum name rejected by the guard
    finally:
        appmod.SAMPLES_DIR = old


# --- catalogue memoization (F-61) ---------------------------------------------------------
#
# VALIDATION REALITY, stated because it is not obvious from anywhere else in the tree: NOTHING
# RUNS THESE. `bin/ci --list` has no python gate, and `grep pytest .github/workflows/` returns
# nothing, so every test in this file is executed by no gate and no workflow — it runs only when
# a person types the command. `sidecar/boxes/.venv` is git-ignored on top of that, so a fresh
# clone cannot run it at all without building the venv first. Treat what follows as documentation
# with an assert in it. Adding a gate is its own decision: CLAUDE.md §14e requires config/ci.rb and
# .github/workflows/ci.yml to move together, and it would put a python toolchain on the critical
# path of every PR for a GPL tree the Rails process never loads.


def test_the_catalogue_is_memoized_but_callers_still_get_their_own_dict():
    """_all_generators() returned a FRESH dict per call before it was memoized, so handing back the
    cached object would silently turn a local into shared process state. Poison what one caller got
    and the next caller must be unaffected."""
    first = appmod._all_generators()
    assert "ABox" in first
    first["POISON"] = object()
    first.pop("ABox")

    second = appmod._all_generators()
    assert "POISON" not in second, "a caller mutated the shared catalogue"
    assert "ABox" in second, "a caller's deletion reached the shared catalogue"
    assert first is not second

    # Same contract on the derived view.
    off_first = appmod._offered_catalogue()
    off_first["POISON"] = object()
    assert "POISON" not in appmod._offered_catalogue()


def test_the_offered_catalogue_is_a_view_of_the_full_one_not_a_replacement():
    """_seeded_default drives TrayLayoutFile, which _offered() excludes — so the full catalogue must
    stay reachable. Collapsing the two would break TrayLayout's seeded textarea, which is a silent
    failure (the form just comes back with a blank layout that then 422s on render)."""
    everything = appmod._all_generators()
    offered = appmod._offered_catalogue()
    assert "TrayLayoutFile" in everything
    assert "TrayLayoutFile" not in offered
    assert set(offered) < set(everything)
    assert offered == {k: c for k, c in everything.items() if appmod._offered(c)}


def test_two_generators_calls_return_identical_json():
    """The catalogue is immutable for the life of the process (BOXES_GENERATOR_PATH is set nowhere,
    and upstream mutates __path__ in place if it ever is), so memoizing must not change a single
    byte of what this endpoint answers. Compares two REAL responses to each other rather than to a
    recomputed expectation, which could drift the same way twice."""
    c = client()
    first = c.get("/generators").get_json()
    second = c.get("/generators").get_json()
    assert first == second
    assert len(first) > 150
    assert {g["key"] for g in first} == {g["key"] for g in second}


def test_the_flat_params_key_is_the_non_advanced_groups_and_nothing_else():
    """F-62. PINS the back-compat `params` key; it is deliberately NOT deleted here.

    What it is: `params` was the whole schema before `param_groups` existed, and it is now the
    non-advanced groups flattened. Measured against the live sidecar, it therefore OMITS 2403 of
    the 5082 params in `param_groups` -- 47%, across 150 of the 181 offered generators. Everything
    in every advanced group is gone: `Settings for Finger Joints` (on 144 generators), `Settings
    for the Lid`, every `Mounting_*`, `Settings for Stackable Edges` (30), `Settings for Flex` (19).
    A consumer reading only this key renders a form that silently cannot reach half the knobs.

    WHY THE DELETION CANNOT HONESTLY BE MADE FROM THIS REPO, which is the point of pinning it
    rather than removing it:

      1. Nothing in this tree reads it. The vendored bundle snapshot under test/fixtures/addons/
         reads `param_groups` (editor.js) and `group.params` (fields.js); every other in-repo hit
         for "params" is `state.data["params"]` -- a saved box's VALUES -- or `request.params`,
         unrelated things sharing the name.
      2. But the DEPLOYED bundle is chaim354/tinkerex-addons, out of this tree, and CLAUDE.md 14c
         is explicit that publishing a bundle IS the deploy with Rails never rebuilt. So an older
         published bundle still reading this key would get an EMPTY FORM, not an error -- the
         quietest possible failure, and invisible to every gate here.
      3. The vendored copy has no sync guard on this side, so its agreement proves nothing about
         what is live.

    SO, BEFORE DELETING THE KEY: grep chaim354/tinkerex-addons for `.params` on a generator object
    -- AND any pinned older build still being served, not just the tip. Until then this test makes
    the eventual deletion a one-line visible diff instead of a silent contract change.

    NOTE this key has nothing to do with CLAUDE.md 14c's license/attribution/source_url rule. That
    belongs to the OPENSCAD sidecar's /generators (sidecar/openscad/app.py, which has a catalog);
    the boxes sidecar carries no licence field at all and no catalog directory, so nothing here is
    load-bearing for a compliance display.
    """
    data = client().get("/generators").get_json()
    assert len(data) > 150

    total = flat_total = 0
    for g in data:
        expected = [p for grp in g["param_groups"] if not grp["advanced"] for p in grp["params"]]
        assert g["params"] == expected, f"{g['key']}: flat `params` is not the non-advanced groups"
        total += sum(len(grp["params"]) for grp in g["param_groups"])
        flat_total += len(g["params"])

    # The omission is the reason the key is worth a comment at all — assert it is real, so this
    # test cannot pass on a build where `params` quietly became a full copy of `param_groups`.
    assert flat_total < total
    assert total - flat_total > 2000, f"only {total - flat_total} params omitted, of {total}"

    # Named instances, so a reader can see the shape of what is missing rather than a number.
    abox = next(g for g in data if g["key"] == "ABox")
    flat_names = {p["name"] for p in abox["params"]}
    grouped_names = {p["name"] for grp in abox["param_groups"] for p in grp["params"]}
    assert {"x", "y", "h"} <= flat_names
    assert "FingerJoint_style" in grouped_names
    assert "FingerJoint_style" not in flat_names


def test_edge_choices_carry_the_descriptions_boxes_pys_own_ui_puts_in_the_dropdown():
    """An edge param's choices are single LETTERS, and a letter on its own is not a choice a user can
    make. boxes.py's own web UI never shows them bare: `ArgparseEdgeType.html` renders each option as
    "{char} {description}" out of `edges.getDescriptions()`. We advertise that map as
    `choice_labels` so the form can do the same.

    Keyed on the action TYPE carrying a `names` map — the same mirror-the-rule move `_multiline` and
    `_offered` make — not on a list of param names: `bottom_edge`/`top_edge` are the two a user
    meets first, but this boxes.py declares edge params under EIGHT more dests (`right_edge`,
    `left_edge`, `back_edge`, `sideedges`, `side_edges`, `panel_edge`, `edgetype`, `edge_style`),
    and a name list would leave those bare while looking finished.
    """
    bottom = _params("TypeTray")["bottom_edge"]
    assert bottom["choices"] == ["F", "h", "s", "e"], "the pinned boxes.py's own order and set"
    assert bottom["choice_labels"] == {
        "F": "Finger Joint (opposing side)",
        "h": "Edge (parallel Finger Joint Holes)",
        "s": "Stackable (bottom, finger joint holes)",
        "e": "Straight Edge",
    }

    top = _params("TypeTray")["top_edge"]
    assert top["choice_labels"]["f"] == "Finger Joint"
    assert top["choice_labels"]["e"] == "Straight Edge"

    # An ordinary enum has no description map upstream, and inventing one is not this endpoint's job:
    # ABSENT, so the form falls back to the bare value rather than rendering "rectangular — ".
    assert _params("ABox")["FingerJoint_style"]["choice_labels"] is None
    assert _params("ABox")["x"]["choice_labels"] is None


def test_every_edge_choice_on_every_generator_has_a_label():
    """Breadth, for the same reason `test_every_generator_renders_with_its_own_advertised_defaults`
    is a sweep: a label map that covers `top_edge` and quietly misses one letter of `sideedges` leaves
    a lone "Š" in a dropdown, and nobody would have thought to single that generator out.

    A MISSING label is the failure mode to watch — upstream builds its map from every BaseEdge
    subclass that declares a `char`, so a choice whose letter is not in it is a boxes.py bump we have
    not noticed, not a cosmetic gap.
    """
    bare = []
    for g in client().get("/generators").get_json():
        for grp in g["param_groups"]:
            for p in grp["params"]:
                labels = p["choice_labels"]
                if labels is None:
                    continue
                bare += [(g["key"], p["name"], c) for c in p["choices"] if not labels.get(c)]
    assert not bare, f"{len(bare)} edge choice(s) would render as a bare letter: {bare[:10]}"
    # ...and the sweep must actually have swept something, or it asserts nothing at all — the
    # vacuous-guard shape (an empty set satisfies "no bare choices" perfectly). Measured against the
    # pinned boxes.py: 45 labelled params across the 10 dests listed above, of which bottom_edge (21)
    # and top_edge (13) are the bulk. The floors are under those so an upstream bump that adds or
    # drops a generator does not fail this, while a rule that stopped matching does.
    labelled = [p["name"] for g in client().get("/generators").get_json()
                for grp in g["param_groups"] for p in grp["params"] if p["choice_labels"]]
    assert len(labelled) >= 40, f"only {len(labelled)} labelled params — the rule stopped matching"
    assert len(set(labelled)) >= 5, f"only {sorted(set(labelled))} — this is matching a name, not a rule"
