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
