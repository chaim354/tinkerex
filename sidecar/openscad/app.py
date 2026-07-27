# openscad-sidecar — GPL-2.0 (ships OpenSCAD; see LICENSE / README).
#
# A thin JSON API over the OpenSCAD binary: list the bundled catalog, derive a Customizer parameter
# schema from ARBITRARY source, and render source+params to 3MF. Runs as an isolated internal-only
# sidecar; the permissive Tinkerex Rails app calls it over HTTP and never imports this code.
#
# THERE IS ONE RENDER PATH AND TWO SOURCES OF .scad (spec §3.1). `POST /render` takes source TEXT
# and never a catalog key. Rails does not hold the catalog source — this sidecar does — so Rails
# FETCHES it (`GET /source/<key>`) and then posts it exactly as it posts a bring-your-own file's
# bytes. After that fetch the two are indistinguishable to every line of code downstream. Do NOT
# "optimize" a generator_key shortcut into /render: that is two caches, two error surfaces, and a
# catalog free to drift from bring-your-own behaviour.
import functools
import json
import os
import re

from flask import Flask, request, jsonify, Response

import render
import schema

app = Flask(__name__)
# A generator is a text file; anything larger is not one. Bounds the parser and the cache key.
app.config["MAX_SCAD_BYTES"] = int(os.environ.get("OPENSCAD_MAX_SCAD_BYTES", "1000000"))

CATALOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog")
# The key indexes a file on OUR disk. Reject anything that is not a bare slug rather than trying to
# normalize it — `..` inside a name that later gets joined is how a read escapes the directory.
KEY_RE = re.compile(r"\A[A-Za-z0-9_-]+\Z")


def _catalog():
    # encoding is EXPLICIT on every read in this file. Python's default follows the locale, which is
    # C.UTF-8 only because the base image happens to set LANG; a vendored generator with a degree
    # sign or an author's accented name would otherwise be a UnicodeDecodeError that /generators
    # swallows as "this one won't derive" and silently drops from the catalog.
    with open(os.path.join(CATALOG_DIR, "catalog.json"), encoding="utf-8") as f:
        return json.load(f)


def _source_path(key):
    if not KEY_RE.match(key or ""):
        return None
    entry = next((e for e in _catalog() if e["key"] == key), None)
    if entry is None:
        return None
    path = os.path.join(CATALOG_DIR, entry["file"])
    # Belt and braces: the file name comes from our own catalog.json, but confirm the resolved path
    # is still inside CATALOG_DIR before opening it.
    root = os.path.realpath(CATALOG_DIR)
    if os.path.commonpath([os.path.realpath(path), root]) != root:
        return None
    return path if os.path.isfile(path) else None


@functools.lru_cache(maxsize=32)
def _schema_for(scad):
    """Source text -> the normalized schema Rails renders.

    MEMOIZED BY SOURCE TEXT, because deriving a schema forks the OpenSCAD binary (~100 ms) and both
    callers ask the same question repeatedly: the catalog is immutable inside the image, and a user
    tweaking a form re-posts the SAME source on every submit. Bounded, because /params takes
    arbitrary source — 32 entries capped by MAX_SCAD_BYTES each. lru_cache does not memoize
    exceptions, so a RenderError still surfaces on every call rather than being cached as a verdict.
    """
    return schema.normalize(render.params_for(scad))


@app.get("/up")
def up():
    return "ok", 200


@app.get("/generators")
def generators():
    """The bundled catalog + each generator's derived parameter schema."""
    out = []
    for entry in _catalog():
        path = _source_path(entry["key"])
        if path is None:
            continue
        item = {k: entry.get(k) for k in ("key", "title", "description", "license",
                                          "attribution", "source_url")}
        try:
            with open(path, encoding="utf-8") as f:
                item.update(_schema_for(f.read()))
        except Exception:
            # A generator whose schema will not derive is skipped, not a 500 for the whole list —
            # the same posture the boxes sidecar takes for an uninspectable generator.
            continue
        out.append(item)
    return jsonify(out)


@app.get("/source/<key>")
def source(key):
    """The raw .scad for a catalog key. This is what keeps ONE render path (spec §3.1): Rails fetches
    catalog source here and then posts it to /render exactly as it posts a bring-your-own file's
    bytes, so nothing downstream can tell the two apart."""
    path = _source_path(key)
    if path is None:
        return jsonify({"error": "unknown generator"}), 404
    with open(path, encoding="utf-8") as f:
        # mimetype= takes a BARE type — Flask appends "; charset=utf-8" to text/* itself. Passing the
        # charset in here emitted "text/plain; charset=utf-8; charset=utf-8", which is malformed.
        return Response(f.read(), mimetype="text/plain")


def _scad_from(body):
    scad = (body or {}).get("scad")
    if not isinstance(scad, str) or not scad.strip():
        return None, "no .scad source supplied"
    if len(scad.encode("utf-8")) > app.config["MAX_SCAD_BYTES"]:
        return None, f"source exceeds {app.config['MAX_SCAD_BYTES']} bytes"
    return scad, None


@app.post("/params")
def params():
    scad, err = _scad_from(request.get_json(force=True, silent=True))
    if err:
        return jsonify({"error": err}), 422
    try:
        return jsonify(_schema_for(scad))
    except render.RenderError as e:
        return jsonify({"error": str(e)}), 422


@app.post("/render")
def do_render():
    body = request.get_json(force=True, silent=True) or {}
    scad, err = _scad_from(body)
    if err:
        return jsonify({"error": err}), 422
    fmt = body.get("format") or "3mf"
    if fmt != "3mf":
        # Spec §12: 3MF only in v1. Refuse explicitly rather than passing an unknown suffix to
        # OpenSCAD, whose error for that is far less clear.
        return jsonify({"error": f"unsupported format {fmt!r}"}), 422
    vectors = {p["name"] for p in _safe_params(scad)["params"] if p["type"] == "vector"}
    try:
        result = render.render(scad, body.get("params") or {}, fmt, vector_names=vectors)
    except render.RenderError as e:
        # A client condition (bad source / bad params), never a 500.
        return jsonify({"error": str(e)}), 422
    resp = Response(result.bytes, mimetype="model/3mf")
    resp.headers["X-Openscad-Cache"] = "hit" if result.cached else "miss"
    return resp


def _safe_params(scad):
    """Vector params need re-bracketing on the way in, which means knowing which they are. A schema
    failure here must not fail the render — worst case a vector field is passed through verbatim,
    and the render itself reports the real problem."""
    try:
        return _schema_for(scad)
    except Exception:
        return {"params": [], "param_groups": []}
