import os

import pytest

from app import app, _catalog, _source_path, CATALOG_DIR


@pytest.fixture
def client():
    app.config.update(TESTING=True)
    return app.test_client()


NEEDS_BIN = pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                               reason="needs the real OpenSCAD binary (run inside the image)")


def test_up(client):
    r = client.get("/up")
    assert r.status_code == 200 and r.data == b"ok"


@NEEDS_BIN  # /generators DERIVES each schema by forking OpenSCAD; without the binary every entry is
            # skipped and the list is legitimately empty. The licence rule below is what must hold
            # everywhere, so it reads the catalog instead of this endpoint.
def test_generators_lists_the_bundled_catalog_with_its_licence(client):
    gens = client.get("/generators").get_json()
    assert isinstance(gens, list) and gens, "the bundled catalog must not be empty"
    g = gens[0]
    # Spec §2: a bundled generator without a recorded licence is exactly what the catalog rule
    # exists to prevent, so the API surfaces it rather than hiding it in a file.
    assert {"key", "title", "description", "license", "attribution", "source_url"} <= set(g)
    assert g["license"]
    assert "param_groups" in g


def test_generators_never_advertises_a_noncommercial_or_sharealike_licence():
    # Spec §2, made mechanical. NC/SA output terms are the trap that motivated the whole section;
    # a future contributor adding a generator gets stopped here rather than in review.
    #
    # READS THE CATALOG, NOT /generators, FOR TWO REASONS — both learned by running it. Going
    # through the endpoint made this test VACUOUS wherever the binary is absent (every entry is
    # skipped, so it iterated an empty list and passed), which is exactly the host where a
    # contributor adds a generator. And /generators SKIPS an entry whose schema will not derive, so
    # a forbidden licence on a non-deriving generator would never have been looked at. The catalog
    # is the thing that gets advertised; nothing can be advertised without being in it.
    entries = _catalog()
    assert entries, "the bundled catalog must not be empty"
    banned = ("-NC", "NonCommercial", "-SA", "ShareAlike", "GPL", "AGPL")
    for g in entries:
        assert g.get("license"), f"{g['key']} has no recorded licence"
        assert not any(b.lower() in g["license"].lower() for b in banned), \
            f"{g['key']} has a forbidden licence: {g['license']}"


def test_source_returns_the_raw_scad_for_a_catalog_key(client):
    # The key comes from the catalog rather than from /generators: reading source needs no binary,
    # and sourcing the key from an endpoint that does would couple this test to one it does not use.
    key = _catalog()[0]["key"]
    r = client.get(f"/source/{key}")
    assert r.status_code == 200
    assert b"=" in r.data, "expected .scad source"
    # Flask appends the charset to a text/* mimetype itself; passing one in emitted a malformed
    # "text/plain; charset=utf-8; charset=utf-8". Caught over real HTTP, pinned here.
    assert r.headers["Content-Type"].count("charset") == 1, r.headers["Content-Type"]
    assert r.mimetype == "text/plain"


def test_source_rejects_a_traversing_key(client):
    # The key indexes a file on our disk, so it must never be usable as a path.
    assert client.get("/source/..%2f..%2fetc%2fpasswd").status_code in (404, 400)
    assert client.get("/source/nope-not-a-generator").status_code == 404


def test_source_path_refuses_every_traversal_shape_bypassing_the_router():
    # THE TEST ABOVE CANNOT FAIL, and that is why this one exists. Flask's <key> converter matches
    # ONE path segment and Werkzeug decodes %2f before routing, so a key containing a slash never
    # reaches the view at all — verified by mutation: deleting BOTH the slug guard AND the
    # catalog-membership lookup, and joining the key straight onto the catalog dir, still passed it.
    # Containment lives in the resolver, so drive the resolver, where a refactor could really break.
    # "../probe" is not a decorative case: probe.scad really does sit one level above catalog/, so a
    # naive join(CATALOG_DIR, key + ".scad") serves a file from outside the catalog. It is the case
    # that fails if the realpath containment check — the last of the three layers — is ever dropped.
    for bad in ("../probe", "../probe.scad", "../../etc/passwd", "/etc/passwd", "..", ".", "", None,
                "probe_plate.scad", "probe_plate/../../../etc/passwd", "..%2f..%2fetc%2fpasswd",
                "probe_plate\x00", "a/b"):
        assert _source_path(bad) is None, f"{bad!r} resolved to a path"
    root = os.path.realpath(CATALOG_DIR)
    good = _source_path(_catalog()[0]["key"])
    assert good, "a real catalog key must still resolve"
    assert os.path.realpath(good).startswith(root + os.sep)


@NEEDS_BIN
def test_params_derives_a_schema_from_arbitrary_source(client):
    src = "/* [G] */\n// how many\ncols = 4;\nwall = 1.5;\ncube([cols, wall, 1]);\n"
    body = client.post("/params", json={"scad": src}).get_json()
    names = {p["name"] for p in body["params"]}
    assert {"cols", "wall"} <= names
    assert body["param_groups"][0]["title"] == "G"


@NEEDS_BIN
def test_params_on_a_file_with_no_parameters_is_an_empty_list_not_an_error(client):
    body = client.post("/params", json={"scad": "cube(10);\n"}).get_json()
    assert body["params"] == []


@NEEDS_BIN
def test_render_returns_3mf_bytes(client):
    src = "cols = 2;\ncube([cols, 1, 1]);\n"
    r = client.post("/render", json={"scad": src, "params": {"cols": 3}, "format": "3mf"})
    assert r.status_code == 200
    assert r.mimetype == "model/3mf"
    assert r.data[:2] == b"PK"


@NEEDS_BIN
def test_render_reports_a_cache_hit_in_a_header(client):
    src = "cols = 5;\ncube([cols, 1, 1]);\n"
    a = client.post("/render", json={"scad": src, "params": {}})
    b = client.post("/render", json={"scad": src, "params": {}})
    assert a.headers.get("X-Openscad-Cache") == "miss"
    assert b.headers.get("X-Openscad-Cache") == "hit"
    assert a.data == b.data


@NEEDS_BIN
def test_a_broken_scad_is_422_not_500(client):
    r = client.post("/render", json={"scad": "not scad {{{", "params": {}})
    assert r.status_code == 422
    assert "error" in r.get_json()


def test_render_without_source_is_422(client):
    assert client.post("/render", json={"params": {}}).status_code == 422


def test_render_rejects_an_oversized_source(client):
    r = client.post("/render", json={"scad": "x" * (app.config["MAX_SCAD_BYTES"] + 1), "params": {}})
    assert r.status_code == 422
