"""Render path. The OpenSCAD binary is real here (these run inside the built image), but the cache
and param-file construction are pure logic and are tested directly."""
import json
import os
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
