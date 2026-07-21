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
