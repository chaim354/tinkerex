"""Coerce the values a client submitted for a .scad's Customizer parameters against the schema this
sidecar derived for that same source — and REFUSE what will not coerce.

WHY THIS EXISTS, and why it must never be "simplified" back to a pass-through: A GARBAGE PARAMETER
VALUE RENDERS SUCCESSFULLY, WITH THE DEFAULT GEOMETRY. Observed against a real render, not reasoned
— `{"cols": "))("}` comes back 200, because OpenSCAD's parameterSet silently IGNORES a value it
cannot parse. So without this, a user's typo yields a default-sized model, saved into their library,
with no feedback anywhere. Silent wrong output is the failure mode this project treats as worst, so
every submitted value is checked against its DECLARED type and anything that will not coerce is
refused instead of travelling on.

THIS GUARD LIVED IN RAILS (`app/services/openscad_params.rb`) UNTIL 2026-08-12, AND THERE MUST NEVER
BE TWO COPIES OF IT. It moved here because a browser bundle cannot call a Rails service object, and
the /tools addon migration makes a bundle the caller. A check that runs on one caller's path and
silently does not on another's is this repo's recorded failure shape; the fix is one copy, at the
door every caller goes through — which is this sidecar, since Rails and a bundle both reach OpenSCAD
only through /render.

The types are schema.py's normalized set — int / float / bool / vector / enum / str — and a param
carrying `choices` is an enum whatever its type says (schema.py's TRAP 3).

What this deliberately does NOT do: enforce min/max. Those are hints the form renders as input
attributes; OpenSCAD HONOURS an out-of-range number rather than ignoring it, so an out-of-range
value is not the silent-default failure this module exists to stop — refusing it would only add
false rejections.
"""
import math


class InvalidParams(Exception):
    """A CLIENT condition: the submitted value is wrong, not the deployment. app.py turns this into
    a 422 whose body carries the message, never a 500."""


# Deliberately an ALLOWLIST. The obvious alternative — "anything not in the false list is true",
# which is what most framework boolean casts do — maps garbage silently to `true`, the exact shape
# of bug this module exists to stop.
BOOL_TRUE = ("true", "1", "on", "yes")
BOOL_FALSE = ("false", "0", "off", "no")

# Keeps an error message bounded when the offending value is a paste rather than a typo. Mirrors
# ActiveSupport's String#truncate, which the Ruby original used: the omission is INSIDE the budget,
# so the result is never longer than SHOWN.
SHOWN = 40


def coerce(submitted, param_groups):
    """submitted: {name: scalar}, straight off the client. param_groups: the normalized groups
    schema.py derived for THIS source. -> {name: coerced value}, ready for render.param_set_json.

    Raises InvalidParams.
    """
    submitted = submitted or {}
    # NOTHING SUBMITTED NEEDS NO SCHEMA, and this ordering is load-bearing: a source whose schema
    # will not derive must still render with its own defaults, which is what /render did before this
    # module existed.
    if not submitted:
        return {}
    if not isinstance(submitted, dict):
        raise InvalidParams("parameters must be an object of name/value pairs")
    # FAIL CLOSED. Nothing submitted can be checked without a schema, and forwarding unchecked
    # values is exactly the silent-default bug above. Unreachable from app.py, which derives the
    # schema itself and surfaces the derivation's own error instead — but this module is what a
    # caller hands values to, so a caller with no schema gets a refusal rather than a pass-through.
    if param_groups is None:
        raise InvalidParams("couldn't read this design's parameters, so the values you entered "
                            "can't be checked")

    declared = {str(p["name"]): p for g in param_groups for p in (g.get("params") or [])}
    return {str(name): _one(declared, str(name), value) for name, value in submitted.items()}


def _one(declared, name, value):
    spec = declared.get(name)
    # The form is BUILT from this same schema, so an undeclared name cannot come from it — refusing
    # costs the UI nothing and is honest: OpenSCAD would ignore it, leaving the user with default
    # geometry and no clue why.
    if spec is None:
        raise InvalidParams(f"{_show(name)} isn't a parameter of this design")
    if not _scalar(value):
        raise InvalidParams(f"{_show(name)} must be a single value")
    # TRAP 3: `choices` wins over `type` — an enum's declared type is the type of its VALUES.
    if spec.get("choices"):
        return _choice(spec, value)

    kind = str(spec.get("type"))
    if kind == "bool":
        return _boolean(spec, value)
    if kind == "int":
        return _integer(spec, value)
    if kind == "float":
        return _number(spec, value)
    if kind == "vector":
        return _vector(spec, value)
    return _text(value)  # "str", and any type a future schema.py adds: text is text.


def _scalar(value):
    # A forged `params[cols][]=1` arrives as a LIST over the wire, and str() on one would hand
    # OpenSCAD "['1']". (bool is a subclass of int in Python and so is already covered; naming it is
    # documentation that a submitted `true` is a legitimate scalar here, not a second branch.)
    return value is None or isinstance(value, (str, int, float, bool))


def _text(value):
    """RUBY'S `to_s`, NOT PYTHON'S `str` — this is a port, and the two disagree on exactly the values
    that matter. `str(None)` is "None" where Ruby gives "", so a cleared field would stop reading as
    blank; `str(True)` is "True" where Ruby gives "true", so a JSON `true` posted to a str param
    would be recorded with a capital letter and one posted to an enum would stop matching a "true"
    choice. Both silent, both landing back on the default geometry."""
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def _choice(spec, value):
    # Values and LABELS stay apart (OpenSCAD's `// [10:S,20:M]` gives a NUMERIC value a human label),
    # so match on the VALUE and hand back the DECLARED one — 10, not "10".
    text = _text(value)
    for choice in spec["choices"]:
        if _text(choice) == text:
            return choice

    allowed = ", ".join(_text(c) for c in spec["choices"])
    raise InvalidParams(f"{_name_of(spec)} must be one of {allowed} (got {_show(value)})")


def _boolean(spec, value):
    text = _text(value).strip().lower()
    if text in BOOL_TRUE:
        return True
    if text in BOOL_FALSE:
        return False

    raise InvalidParams(f"{_name_of(spec)} must be true or false (got {_show(value)})")


def _integer(spec, value):
    n = _number(spec, value)
    if n % 1 != 0:
        raise InvalidParams(f"{_name_of(spec)} must be a whole number (got {_show(value)})")

    return int(n)


def _number(spec, value):
    """-> int when the value is integral, else float. The narrowing mirrors schema.py's `_num`,
    which turns OpenSCAD's all-floats dump into 4 rather than 4.0 — so a value round-trips through
    the form the way it arrived instead of growing a ".0" on every save."""
    try:
        f = float(_text(value).strip())
    except ValueError:
        # Covers blank AND garbage. A blank number field is refused ON PURPOSE: silently falling
        # back to the default is the failure mode here, not the fix.
        raise InvalidParams(f"{_name_of(spec)} must be a number (got {_show(value)})") from None
    if not math.isfinite(f):
        # "1e400" parses to inf and "nan"/"inf" parse to themselves; any of them would reach OpenSCAD
        # as literal text it cannot use and be ignored, landing back on the default. (Ruby's Float()
        # refused the words outright and only overflow reached this check; Python's float() accepts
        # them, so here it does both jobs.)
        raise InvalidParams(f"{_name_of(spec)} must be a number (got {_show(value)})")

    return int(f) if f.is_integer() else f


def _vector(spec, value):
    """-> the OpenSCAD literal "[a,b,c]", ALREADY BRACKETED. render.param_set_json re-brackets a bare
    "10,20,30" itself, but only when the value contains a comma — so a ONE-element vector would
    arrive as the scalar `10`, which OpenSCAD type-mismatches and silently ignores, landing back on
    the default geometry. Emitting the literal here means the value never depends on that
    heuristic (nor on the caller having correctly worked out which params ARE vectors)."""
    text = _text(value).strip()
    if text.startswith("["):
        text = text[1:]
    if text.endswith("]"):
        text = text[:-1]
    parts = [p.strip() for p in text.split(",")]
    if not parts or any(p == "" for p in parts):
        raise InvalidParams(f"{_name_of(spec)} must be numbers separated by commas "
                            f"(got {_show(value)})")

    return "[" + ",".join(_text(_number(spec, p)) for p in parts) + "]"


def _name_of(spec):
    return _show(spec.get("name"))


def _show(value):
    return f"“{_truncate(_text(value))}”"


def _truncate(text):
    return text if len(text) <= SHOWN else text[:SHOWN - 3] + "..."
