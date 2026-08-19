"""Render path. The OpenSCAD binary is real here (these run inside the built image), but the cache
and param-file construction are pure logic and are tested directly."""
import json
import os
import subprocess
import tempfile

import pytest

import render


SIMPLE = "/* [P] */\ncols = 2;\nlabel = \"hi\";\ncube([cols, 1, 1]);\n"


def test_cache_key_changes_with_every_input_that_can_change_the_bytes():
    a = render.cache_key(SIMPLE, {"cols": 2}, "3mf", "2026.07.26")
    assert a == render.cache_key(SIMPLE, {"cols": 2}, "3mf", "2026.07.26")     # stable
    assert a != render.cache_key(SIMPLE, {"cols": 3}, "3mf", "2026.07.26")     # params
    assert a != render.cache_key(SIMPLE + "\n", {"cols": 2}, "3mf", "2026.07.26")  # source
    assert a != render.cache_key(SIMPLE, {"cols": 2}, "stl", "2026.07.26")     # format
    # VERSION IS IN THE KEY ON PURPOSE (spec §5.1): a version bump can legitimately change output
    # geometry, and a stale cache would serve the old mesh forever.
    assert a != render.cache_key(SIMPLE, {"cols": 2}, "3mf", "2027.01.01")


def test_cache_key_is_insensitive_to_param_ordering():
    # Two identical renders must not miss the cache because a dict serialized differently.
    assert render.cache_key(SIMPLE, {"a": 1, "b": 2}, "3mf", "v") == \
           render.cache_key(SIMPLE, {"b": 2, "a": 1}, "3mf", "v")


def test_param_set_stringifies_every_value_including_bools_and_vectors():
    # OpenSCAD's parameterSets format takes STRINGS. A raw Python bool serializes as `true`, which
    # OpenSCAD does not accept, and a list serializes as `[1, 2]` with spaces.
    body = json.loads(render.param_set_json({"n": 4, "flag": False, "v": [1, 2, 3], "s": "x"}))
    values = body["parameterSets"]["s"]
    assert values["n"] == "4"
    assert values["flag"] == "false"
    assert values["v"] == "[1,2,3]"
    assert values["s"] == "x"


def test_a_comma_string_from_a_vector_field_is_rebracketed():
    # schema.py renders a vector default as "10,20,30" for a text input; it must go back as a
    # bracketed OpenSCAD vector, not the bare string.
    values = json.loads(render.param_set_json({"span": "10,20,30"}, vector_names={"span"}))["parameterSets"]["s"]
    assert values["span"] == "[10,20,30]"


# --- the version probe, which is IN THE CACHE KEY -------------------------------------------------

REAL = "OpenSCAD version 2026.07.26"


@pytest.fixture
def cold_version_memo():
    """openscad_version memoizes on a module global, so a test about it must start from cold — and
    must put back whatever a real-binary test in this file already resolved."""
    before = render._VERSION
    render._VERSION = None
    yield
    render._VERSION = before


def _probe(monkeypatch, forks, healthy):
    """Stand in for `openscad --version`, counting forks. `healthy` is read at CALL time so a test
    can flip the box's behaviour between calls."""
    def fake_run(cmd, **kw):
        forks.append(cmd)
        if not healthy[0]:
            raise OSError("fork: Resource temporarily unavailable")
        return subprocess.CompletedProcess(cmd, 0, stdout=REAL + "\n", stderr="")
    monkeypatch.setattr(subprocess, "run", fake_run)


def test_the_version_probe_forks_ONCE_PER_PROCESS_not_once_per_render(cold_version_memo, monkeypatch):
    # The version is a CONSTANT OF THE PROCESS — OPENSCAD_BIN resolves once at import and the
    # Dockerfile bakes the binary in — but it was being asked per request, before the cache lookup,
    # so even a pure cache hit forked a Qt-linked binary before touching the disk.
    forks = []
    _probe(monkeypatch, forks, [True])
    assert [render.openscad_version() for _ in range(4)] == [REAL] * 4
    assert len(forks) == 1, "the probe must be memoized, not re-run per render"


def test_a_BLIPPED_probe_cannot_give_IDENTICAL_INPUT_A_SECOND_CACHE_KEY(cold_version_memo, monkeypatch):
    # THE INVALID STATE BEING REMOVED. openscad_version swallows any failure into the literal
    # "unknown", and that string is hashed into cache_key — so one transient fork failure used to
    # write the same (scad, params, fmt) under a second key no healthy request would ever read, and
    # (probed against a persistent cache dir) served the PRE-UPGRADE mesh after an OpenSCAD bump.
    forks, healthy = [], [True]
    _probe(monkeypatch, forks, healthy)
    first = render.cache_key(SIMPLE, {"cols": 2}, "3mf", render.openscad_version())

    healthy[0] = False                      # the box blips under load
    assert render.openscad_version() == REAL, "a known version must survive a failing probe"
    assert render.cache_key(SIMPLE, {"cols": 2}, "3mf", render.openscad_version()) == first


def test_a_FAILED_probe_is_NOT_remembered(cold_version_memo, monkeypatch):
    # THE HALF A PLAIN functools.lru_cache GETS WRONG, and the reason this is hand-rolled. lru_cache
    # would memoize "unknown" as readily as a real answer, and the gunicorn CMD sets no
    # --max-requests, so one blipped probe at worker start would key every render that worker ever
    # serves under "unknown" — widening the stale-cache window above from one request to a whole
    # worker lifetime. Only a SUCCESS may be remembered.
    forks, healthy = [], [False]
    _probe(monkeypatch, forks, healthy)
    assert render.openscad_version() == "unknown"

    healthy[0] = True
    assert render.openscad_version() == REAL, "a failed probe must not become the process's answer"


@pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                    reason="needs the real OpenSCAD binary (run inside the image)")
def test_render_produces_a_3mf_and_the_second_call_is_a_cache_hit():
    with tempfile.TemporaryDirectory() as cache:
        r1 = render.render(SIMPLE, {"cols": 2}, "3mf", cache_dir=cache)
        assert r1.bytes[:2] == b"PK" and len(r1.bytes) > 0
        assert r1.cached is False
        r2 = render.render(SIMPLE, {"cols": 2}, "3mf", cache_dir=cache)
        assert r2.cached is True
        assert r2.bytes == r1.bytes


@pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                    reason="needs the real OpenSCAD binary (run inside the image)")
def test_a_broken_scad_raises_rendererror_not_a_crash():
    with tempfile.TemporaryDirectory() as cache:
        with pytest.raises(render.RenderError):
            render.render("this is not scad {{{", {}, "3mf", cache_dir=cache)


@pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                    reason="needs the real OpenSCAD binary (run inside the image)")
def test_an_empty_model_is_a_rendererror_not_an_empty_file():
    # OpenSCAD exits nonzero with "Current top level object is empty" — but a lib3mf-less build
    # exits 0 having written nothing, so the size check is the backstop that matters.
    with tempfile.TemporaryDirectory() as cache:
        with pytest.raises(render.RenderError):
            render.render("x = 1;\n", {}, "3mf", cache_dir=cache)
