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
