"""Parameter coercion — the guard that stops a typo from rendering the DEFAULT geometry.

This moved here from Rails (`app/services/openscad_params.rb`) on 2026-08-12; these tests are the
Ruby suite's replacement and there is no longer a second copy of either. Read coerce.py's header for
why the guard exists at all: OpenSCAD's parameterSet SILENTLY IGNORES a value it cannot parse, so a
pass-through gives a garbage value a 200 and a wrong model.

THE SCHEMA UNDER TEST IS DERIVED FROM REAL `--export-format=param` OUTPUT, not hand-written.
Reusing test_schema's captured dump rather than inventing a param_groups literal is the FakeS3
lesson (CLAUDE.md §14e): a fixture invented alongside the code confirms the code's own idea of the
shape instead of catching a mistake in it.
"""
import os

import pytest

import app as sidecar
import coerce
import render
from schema import normalize
from test_schema import REAL_DUMP

# cols int / wall float / rounded bool / label str / mode enum(numeric) / span vector /
# choice enum(string) / ranged int WITH min 1 max 10.
GROUPS = normalize(REAL_DUMP)["param_groups"]

NEEDS_BIN = pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                               reason="needs the real OpenSCAD binary (run inside the image)")


def one(name, value):
    return coerce.coerce({name: value}, GROUPS)[name]


def refusal(name, value):
    with pytest.raises(coerce.InvalidParams) as e:
        coerce.coerce({name: value}, GROUPS)
    return str(e.value)


# --- the types ---------------------------------------------------------------------------------

def test_an_int_field_takes_the_form_string_and_comes_back_an_int():
    assert one("cols", "6") == 6
    # `== 6` is true for 6.0 as well, so the TYPE is the assertion that carries the weight: OpenSCAD
    # renders "6.0" happily, but the value is recorded and round-tripped through a form, where a
    # count that grows a ".0" on every save is the thing schema.py's own narrowing exists to stop.
    assert isinstance(one("cols", "6"), int)


def test_a_float_field_keeps_a_fraction_and_narrows_an_integral_value():
    assert one("wall", "2.5") == 2.5
    assert isinstance(one("wall", "3"), int), "an integral float narrows, mirroring schema.py's _num"


def test_a_str_field_takes_anything_including_what_a_number_field_refuses():
    # "))(" is garbage only for a NUMBER. Refusing it everywhere would be a false rejection, and an
    # engraved label is exactly where a user may legitimately want punctuation.
    assert one("label", "))(") == "))("
    assert one("label", "") == ""


def test_a_bool_field_maps_the_allowlist_and_nothing_else():
    for yes in ("true", "1", "on", "yes"):
        assert one("rounded", yes) is True, yes
    for no in ("false", "0", "off", "no"):
        assert one("rounded", no) is False, no


def test_a_bool_is_matched_case_and_whitespace_insensitively():
    # The checkbox posts "true"/"false", but a bundle or a hand-built request may not.
    assert one("rounded", " True ") is True
    assert one("rounded", "FALSE") is False


def test_garbage_in_a_bool_is_REFUSED_and_never_becomes_true():
    # THE REASON THE ALLOWLIST IS AN ALLOWLIST. The usual framework boolean cast (Rails'
    # ActiveModel::Type::Boolean, and most others) maps everything outside a short FALSE list to
    # true — so "maybe" would render a rounded plate the user never asked for, silently.
    for bad in ("maybe", "2", "", "t", "y", "null"):
        message = refusal("rounded", bad)
        assert "rounded" in message, message
        assert "true or false" in message, message


# --- the numbers -------------------------------------------------------------------------------

def test_the_observed_garbage_case_is_refused_rather_than_rendered():
    # `{"cols": "))("}` is the case that was OBSERVED coming back 200 with the default geometry.
    message = refusal("cols", "))(")
    assert "cols" in message and "must be a number" in message, message


def test_an_int_field_refuses_a_fractional_value():
    assert "whole number" in refusal("cols", "4.5")


def test_a_CLEARED_number_field_is_refused_rather_than_defaulted():
    # Falling back to the default for a blank field IS the failure mode, not the fix: the user
    # cleared it because they meant to change it, and a default-sized model is the wrong answer
    # delivered silently.
    assert "must be a number" in refusal("wall", "")
    assert "must be a number" in refusal("wall", "   ")
    assert "must be a number" in refusal("wall", None)


def test_values_that_are_not_finite_numbers_are_refused():
    # "1e400" OVERFLOWS to infinity and "nan"/"inf" parse to themselves in Python. Any of them
    # reaches OpenSCAD as literal text it cannot use, is ignored, and lands back on the default.
    for bad in ("1e400", "-1e400", "inf", "-inf", "nan", "Infinity"):
        assert "must be a number" in refusal("wall", bad), bad


# --- the enum trap -----------------------------------------------------------------------------

def test_an_enum_hands_back_the_DECLARED_value_not_the_submitted_text():
    # OpenSCAD's `// [1:solid, 2:hollow]` gives a NUMERIC value a human label. The form posts the
    # value as text; what reaches the parameterSet must be the declared 2, not the string "2".
    assert one("mode", "2") == 2
    assert isinstance(one("mode", "2"), int)


def test_posting_an_enum_LABEL_back_is_refused():
    # The half that catches conflating values with labels. "solid" is a type error to OpenSCAD,
    # which means it is ignored — default geometry, silently.
    message = refusal("mode", "solid")
    assert "mode" in message and "must be one of 1, 2" in message, message


def test_a_value_outside_the_declared_choices_is_refused():
    assert "must be one of 1, 2" in refusal("mode", "3")


def test_a_string_enum_comes_back_as_its_declared_string():
    assert one("choice", "a") == "a"
    assert "must be one of a, b" in refusal("choice", "c")


def test_CHOICES_WIN_OVER_TYPE_even_when_the_type_says_otherwise():
    # schema.py's TRAP 3, from the other side. schema.py always labels an options-carrying param
    # "enum", so this shape cannot arrive from it TODAY — which is exactly why the guard needs its
    # own test: read `type` first and a hand-built or future-derived spec silently becomes a plain
    # int field, accepting 15 for a param whose only legal values are 10 and 20.
    groups = [{"title": "T", "advanced": False, "params": [
        {"name": "size", "type": "int", "default": 10, "choices": [10, 20],
         "choice_labels": ["S", "M"], "min": None, "max": None, "step": None,
         "group": "T", "help": ""},
    ]}]
    assert coerce.coerce({"size": "10"}, groups) == {"size": 10}
    with pytest.raises(coerce.InvalidParams):
        coerce.coerce({"size": "15"}, groups)


# --- vectors -----------------------------------------------------------------------------------

def test_a_vector_becomes_a_BRACKETED_openscad_literal():
    assert one("span", "10, 20,30") == "[10,20,30]"


def test_a_ONE_ELEMENT_vector_is_still_bracketed():
    # THE REASON THE LITERAL IS BUILT HERE rather than left to render.param_set_json, whose
    # re-bracketing only fires on a value containing a comma. A bare `10` reaches OpenSCAD as a
    # scalar where a vector is declared — a type mismatch, which is IGNORED, which is the default
    # geometry again.
    assert one("span", "10") == "[10]"


def test_an_already_bracketed_vector_is_accepted_and_not_double_bracketed():
    assert one("span", "[10,20,30]") == "[10,20,30]"


def test_a_vector_element_is_coerced_like_any_other_number():
    assert one("span", "10,2.5,30") == "[10,2.5,30]"


def test_a_HOLE_in_a_vector_is_refused():
    for bad in ("10,,30", "10,20,", ",10,20", "", "[]"):
        assert "separated by commas" in refusal("span", bad), bad


def test_a_non_numeric_vector_element_is_refused():
    assert "must be a number" in refusal("span", "10,x,30")


# --- what this deliberately does NOT do ----------------------------------------------------------

def test_MIN_AND_MAX_ARE_NOT_ENFORCED():
    # DO NOT "IMPROVE" THIS INTO A RANGE CHECK. min/max are hints the form renders as input
    # attributes. OpenSCAD HONOURS an out-of-range number rather than ignoring it, so an
    # out-of-range value is NOT the silent-default failure this module exists to stop — it renders
    # exactly what was asked for. Refusing it would only add false rejections to a guard whose whole
    # value is that it never fires on something that would have worked.
    ranged = next(p for g in GROUPS for p in g["params"] if p["name"] == "ranged")
    assert (ranged["min"], ranged["max"]) == (1, 10), "the fixture must actually declare a range"
    assert one("ranged", "999") == 999
    assert one("ranged", "-5") == -5


# --- the shape of the input ----------------------------------------------------------------------

def test_a_parameter_the_design_does_not_declare_is_refused():
    # The form is BUILT from this schema, so an undeclared name cannot come from it. OpenSCAD would
    # ignore it, leaving the user with default geometry and no clue why.
    assert "isn't a parameter of this design" in refusal("colz", "9")


def test_a_LIST_value_is_refused_rather_than_stringified():
    # A forged `params[cols][]=1` arrives as a list. str() on one would hand OpenSCAD "['1']".
    assert "must be a single value" in refusal("cols", ["1"])
    assert "must be a single value" in refusal("cols", {"a": 1})


def test_nothing_submitted_needs_no_schema():
    # ORDER MATTERS: a source whose schema will not derive must still render with its own defaults,
    # which is what /render did before this module existed.
    assert coerce.coerce({}, None) == {}
    assert coerce.coerce(None, None) == {}


def test_values_submitted_with_NO_schema_fail_CLOSED():
    with pytest.raises(coerce.InvalidParams) as e:
        coerce.coerce({"cols": "6"}, None)
    assert "can't be checked" in str(e.value)


def test_a_params_payload_that_is_not_an_object_is_refused():
    with pytest.raises(coerce.InvalidParams):
        coerce.coerce(["cols", "6"], GROUPS)


# --- the message ----------------------------------------------------------------------------------

def test_a_PASTED_value_cannot_blow_up_the_message():
    # The message travels into a flash and into a bundle's error UI. A 10 kB paste in a number field
    # must not become a 10 kB message.
    message = refusal("cols", "x" * 10_000)
    assert len(message) < 150, len(message)
    # ActiveSupport's String#truncate, which the Ruby original used: the omission is INSIDE the
    # budget, so 40 characters means 37 plus "...", never 43.
    assert "x" * 37 + "..." in message
    assert "x" * 38 not in message


def test_a_value_at_exactly_the_limit_is_shown_whole():
    assert "y" * coerce.SHOWN in refusal("cols", "y" * coerce.SHOWN)


def test_every_refusal_names_the_parameter_it_is_about():
    # Without the name the user is told something is wrong and not which field to look at — and this
    # addon's forms routinely carry twenty of them.
    for name, bad in [("cols", "))("), ("wall", ""), ("rounded", "maybe"), ("span", "10,,30"),
                      ("mode", "9"), ("colz", "1")]:
        assert name in refusal(name, bad), name


# --- what the coerced values do downstream ---------------------------------------------------------

def test_the_coerced_values_serialize_into_openscads_own_parameterSet_format():
    # END OF THE PIPELINE. param_set_json takes STRINGS, and this is where a bool that stayed a
    # Python True or a vector that never got its brackets would show up.
    values = coerce.coerce({"cols": "6", "wall": "2.5", "rounded": "false", "label": "hi",
                            "span": "10,20,30", "mode": "2"}, GROUPS)
    out = render.param_set_json(values)
    import json
    assert json.loads(out)["parameterSets"]["s"] == {
        "cols": "6", "wall": "2.5", "rounded": "false", "label": "hi",
        "span": "[10,20,30]", "mode": "2",
    }


def test_coercing_BEFORE_the_cache_key_keeps_pre_move_cache_entries_valid():
    # THE CACHE IS CONTENT-ADDRESSED OVER THE PARAMS IT IS HANDED. Until this move Rails coerced and
    # the sidecar hashed the COERCED values; now the sidecar coerces first, so the key is computed
    # over the same values it always was and every entry already on the volume still hits. Hash the
    # RAW values instead and the whole cache is orphaned on deploy — not wrong bytes, but a silent
    # full re-render of every design anyone has ever made.
    src = "cols = 4;\ncube([cols, 1, 1]);\n"
    as_rails_used_to_send = {"cols": 6, "wall": 2.5, "rounded": True, "span": "[10,20,30]", "mode": 2}
    now = coerce.coerce({"cols": "6", "wall": "2.5", "rounded": "true", "span": "10,20,30",
                         "mode": "2"}, GROUPS)
    assert now == as_rails_used_to_send
    assert render.cache_key(src, now, "3mf", "v") == \
           render.cache_key(src, as_rails_used_to_send, "3mf", "v")


# --- the route ---------------------------------------------------------------------------------

@pytest.fixture
def client(monkeypatch):
    """A test client whose schema derivation is stubbed, so the ROUTE's error mapping is exercised
    on a box with no OpenSCAD binary. Patched on the module, which is where _coerced looks it
    up. (_safe_params was named here too until F-59 deleted it — the whole point of that commit
    was that the second derivation existed.)"""
    sidecar.app.config.update(TESTING=True)
    monkeypatch.setattr(sidecar, "_schema_for",
                        lambda scad: {"params": [p for g in GROUPS for p in g["params"]],
                                      "param_groups": GROUPS})
    monkeypatch.setattr(render, "render",
                        lambda scad, params, fmt, **kw: render.Result(b"PK\x03\x04", cached=False))
    return sidecar.app.test_client()


SRC = "cols = 4;\ncube([cols, 1, 1]);\n"


def test_render_refuses_a_bad_value_with_the_prose_AND_a_machine_readable_code(client):
    r = client.post("/render", json={"scad": SRC, "params": {"cols": "))("}})
    assert r.status_code == 422
    body = r.get_json()
    # `error` carries the PROSE, because that is the key this sidecar already answers errors in and
    # what a bundle surfaces verbatim through the SDK's ServiceError.
    assert "cols" in body["error"] and "must be a number" in body["error"]
    # `code` is the machine half. THE STATUS ALONE CANNOT TELL THIS APART from a bad .scad — both
    # are 422 — and the caller must: a rejected value is something the user can fix, so Rails hands
    # the editor back with their form still in it rather than bouncing them to the index.
    assert body["code"] == "invalid_params"


def test_a_render_error_is_422_WITHOUT_the_invalid_params_code(client, monkeypatch):
    # The other side of the discriminator. Collapse the two and a broken .scad would re-render the
    # editor claiming the user's values are wrong, when nothing about them is.
    def boom(scad, params, fmt, **kw):
        raise render.RenderError("Parser error: syntax error in line 3")
    monkeypatch.setattr(render, "render", boom)
    r = client.post("/render", json={"scad": SRC, "params": {"cols": "4"}})
    assert r.status_code == 422
    assert "Parser error" in r.get_json()["error"]
    assert "code" not in r.get_json()


def test_a_source_whose_schema_will_not_derive_reports_the_SOURCES_error(client, monkeypatch):
    def boom(scad):
        raise render.RenderError("Parser error: syntax error in line 1")
    monkeypatch.setattr(sidecar, "_schema_for", boom)
    r = client.post("/render", json={"scad": "not scad {{{", "params": {"cols": "4"}})
    assert r.status_code == 422
    assert "Parser error" in r.get_json()["error"], "the .scad's own complaint is the useful one"
    assert "code" not in r.get_json()


def test_a_render_with_NO_params_still_works_when_the_schema_will_not_derive(client, monkeypatch):
    # Preserved from before coercion existed: nothing submitted needs no schema, so a source whose
    # parameters cannot be read must still render with its own defaults.
    def boom(scad):
        raise render.RenderError("could not read parameters")
    monkeypatch.setattr(sidecar, "_schema_for", boom)
    assert client.post("/render", json={"scad": SRC, "params": {}}).status_code == 200
    assert client.post("/render", json={"scad": SRC}).status_code == 200


def test_a_good_value_reaches_the_renderer_COERCED(client, monkeypatch):
    seen = {}
    monkeypatch.setattr(render, "render",
                        lambda scad, params, fmt, **kw: (seen.update(params),
                                                         render.Result(b"PK", cached=False))[1])
    assert client.post("/render", json={"scad": SRC, "params": {"cols": "6"}}).status_code == 200
    assert seen == {"cols": 6}, "the renderer must see the coerced int, not the form's string"


def _renderer_sees(client, monkeypatch, params):
    seen = {}
    monkeypatch.setattr(render, "render",
                        lambda scad, p, fmt, **kw: (seen.update(p),
                                                    render.Result(b"PK", cached=False))[1])
    assert client.post("/render", json={"scad": SRC, "params": params}).status_code == 200
    return seen


def test_a_ONE_ELEMENT_vector_reaches_the_renderer_ALREADY_BRACKETED(client, monkeypatch):
    # THE END-TO-END LINK, and the reason /render can stop computing a vector_names set at all.
    # param_set_json's re-bracketing heuristic needs a comma to fire, so it could NEVER have helped
    # a one-element vector — only coerce._vector can, and this asserts it does, through the route
    # rather than at the unit level where it was already pinned. A bare `10` reaching OpenSCAD where
    # a vector is declared is a type mismatch, which OpenSCAD IGNORES: 200, default geometry, no
    # diagnostic. Mutation-checked by making coerce._vector return its value unbracketed.
    assert _renderer_sees(client, monkeypatch, {"span": "10"}) == {"span": "[10]"}


def test_a_MULTI_ELEMENT_vector_reaches_the_renderer_BRACKETED_WITHOUT_the_heuristic(client, monkeypatch):
    # The case the removed vector_names wiring WAS covering, so it is the one that proves removing
    # it changed nothing: the brackets still arrive, and they arrive from coerce.
    assert _renderer_sees(client, monkeypatch, {"span": "10, 20,30"}) == {"span": "[10,20,30]"}


# --- the premise, against the real binary ----------------------------------------------------------

@NEEDS_BIN
def test_OPENSCAD_REALLY_DOES_IGNORE_A_VALUE_IT_CANNOT_PARSE():
    """THE OBSERVED FACT THIS WHOLE MODULE RESTS ON, pinned rather than asserted in a comment.

    render.render is called DIRECTLY here, bypassing coercion, precisely to reproduce the behaviour
    the guard exists to stop: a garbage value does not error, it renders the DEFAULT geometry. If
    OpenSCAD ever starts refusing one, this test is what says so — and coerce.py's justification
    would then need re-reading rather than being taken on trust.
    """
    import tempfile
    src = "cols = 4;\ncube([cols, 1, 1]);\n"
    with tempfile.TemporaryDirectory() as cache:
        garbage = render.render(src, {"cols": "))("}, "3mf", cache_dir=cache).bytes
        default = render.render(src, {}, "3mf", cache_dir=cache).bytes
        changed = render.render(src, {"cols": 9}, "3mf", cache_dir=cache).bytes
    assert garbage == default, "a garbage value no longer renders the default — re-read coerce.py"
    assert changed != default, "cols must actually move the geometry, or the test above proves nothing"


@NEEDS_BIN
def test_render_refuses_a_bad_value_end_to_end_against_the_real_binary():
    sidecar.app.config.update(TESTING=True)
    c = sidecar.app.test_client()
    src = "cols = 4;\ncube([cols, 1, 1]);\n"
    r = c.post("/render", json={"scad": src, "params": {"cols": "))("}})
    assert r.status_code == 422
    assert r.get_json()["code"] == "invalid_params"
    assert c.post("/render", json={"scad": src, "params": {"cols": "9"}}).status_code == 200
