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
    assert g["title"] and isinstance(g["params"], list)
    names = {p["name"] for p in g["params"]}
    assert {"x", "y", "h"} <= names
    xp = next(p for p in g["params"] if p["name"] == "x")
    assert xp["type"] in ("float", "int") and xp["default"] is not None
    # internal + advanced edge-setting params are hidden
    assert "format" not in names and "output" not in names
    assert not any("_" in n and n[0].isupper() for n in names)


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
