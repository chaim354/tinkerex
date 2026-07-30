"""Schema normalization. Every fixture here is REAL --export-format=param output, captured from
OpenSCAD 2026.07.26 in a container — not hand-invented. A fake built from the same misunderstanding
as the code confirms the misunderstanding (CLAUDE.md §12 step 10, the FakeS3 lesson)."""
from schema import normalize

# Captured verbatim from `openscad --export-format=param` on a probe exercising every type.
REAL_DUMP = {
    "title": "probe",
    "parameters": [
        {"caption": "number of columns", "group": "Grid", "initial": 4.0, "name": "cols",
         "step": 1.0, "type": "number"},
        {"group": "Walls", "initial": 1.6, "name": "wall", "step": 1.0, "type": "number"},
        {"group": "Walls", "initial": True, "name": "rounded", "type": "boolean"},
        {"group": "Walls", "initial": "demo", "name": "label", "type": "string"},
        {"caption": "render mode", "group": "Walls", "initial": 1.0, "name": "mode",
         "options": [{"name": "solid", "value": 1.0}, {"name": "hollow", "value": 2.0}],
         "type": "number"},
        {"group": "Walls", "initial": [10.0, 20.0, 30.0], "name": "span", "type": "number"},
        {"group": "Walls", "initial": "b", "name": "choice",
         "options": [{"name": "a", "value": "a"}, {"name": "b", "value": "b"}], "type": "string"},
        {"group": "Walls", "initial": 5.0, "max": 10.0, "min": 1.0, "name": "ranged",
         "step": 1.0, "type": "number"},
    ],
}


def by_name(result):
    return {p["name"]: p for p in result["params"]}


def test_zero_parameter_file_yields_no_params_and_does_not_crash():
    # THE TRAP: OpenSCAD OMITS the "parameters" key entirely for a file with none — it is not [].
    # `for p in d["parameters"]` raises KeyError and `for p in None` raises TypeError.
    result = normalize({"title": "empty"})
    assert result["params"] == []
    assert result["param_groups"] == []


def test_an_integral_number_becomes_int_not_float():
    # EVERYTHING numeric arrives as a float (4.0, never 4). Without this, a count renders as "4.0"
    # in the form and round-trips back as a float.
    assert by_name(normalize(REAL_DUMP))["cols"]["type"] == "int"
    assert by_name(normalize(REAL_DUMP))["cols"]["default"] == 4


def test_a_fractional_number_stays_float():
    assert by_name(normalize(REAL_DUMP))["wall"]["type"] == "float"
    assert by_name(normalize(REAL_DUMP))["wall"]["default"] == 1.6


def test_boolean_maps_to_bool():
    p = by_name(normalize(REAL_DUMP))["rounded"]
    assert p["type"] == "bool" and p["default"] is True


def test_string_maps_to_str():
    p = by_name(normalize(REAL_DUMP))["label"]
    assert p["type"] == "str" and p["default"] == "demo"


def test_options_make_an_enum_even_though_type_says_number():
    # TRAP: an enum is "type":"number" PLUS "options". Reading `type` first mislabels it as numeric
    # and the form renders a spinner instead of a dropdown.
    p = by_name(normalize(REAL_DUMP))["mode"]
    assert p["type"] == "enum"
    assert p["choices"] == [1, 2]
    assert p["choice_labels"] == ["solid", "hollow"]


def test_string_options_also_make_an_enum():
    p = by_name(normalize(REAL_DUMP))["choice"]
    assert p["type"] == "enum" and p["choices"] == ["a", "b"]


def test_a_vector_is_detected_by_its_value_not_its_type():
    # TRAP: a vector reports "type":"number" with a LIST initial. There is no "vector" type, so
    # branching on `type` renders a number input that cannot hold [10,20,30].
    p = by_name(normalize(REAL_DUMP))["span"]
    assert p["type"] == "vector"
    assert p["default"] == "10,20,30"


def test_min_max_step_are_carried_through():
    p = by_name(normalize(REAL_DUMP))["ranged"]
    assert (p["min"], p["max"], p["step"]) == (1, 10, 1)


def test_caption_becomes_help_and_falls_back_to_the_name():
    params = by_name(normalize(REAL_DUMP))
    assert params["cols"]["help"] == "number of columns"
    # `wall` has NO caption key — OpenSCAD only emits one when a // comment precedes the assignment.
    assert params["wall"]["help"] == ""


def test_params_are_grouped_in_declaration_order():
    groups = normalize(REAL_DUMP)["param_groups"]
    assert [g["title"] for g in groups] == ["Grid", "Walls"]
    # REAL_DUMP has exactly one "Grid" param (cols) — no "rows" appears anywhere in the fixture,
    # so the plan's original `== ["cols", "rows"] or == ["cols"]` had a dead first disjunct.
    assert [p["name"] for p in groups[0]["params"]] == ["cols"]


def test_a_group_named_advanced_is_flagged_advanced():
    dump = {"parameters": [
        {"group": "Advanced", "initial": 1.0, "name": "a", "type": "number"},
        {"group": "Main", "initial": 1.0, "name": "b", "type": "number"},
    ]}
    groups = {g["title"]: g for g in normalize(dump)["param_groups"]}
    assert groups["Advanced"]["advanced"] is True
    assert groups["Main"]["advanced"] is False
