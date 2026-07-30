"""OpenSCAD's Customizer schema -> the normalized shape the Rails form renders.

Rails renders a param as {name, type, default, help, choices, min, max, step}, grouped into
{title, advanced, params} sections — deliberately the SAME shape BoxesClient::Generator uses, so the
two addons' field partials stay near-identical instead of diverging.

Everything here exists because OpenSCAD's dump has five sharp edges (all observed, not assumed):
  1. "parameters" is ABSENT for a zero-param file — not [].
  2. Every number is a float: 4.0, never 4.
  3. An enum is type "number"/"string" PLUS "options" — `type` alone mislabels it.
  4. A vector is type "number" with a LIST initial. There is no "vector" type.
  5. "caption" appears only when a // description comment precedes the assignment.
"""

# OpenSCAD has no notion of an "advanced" group; this is OUR convention, so a catalog author can
# push tuning knobs into a collapsed section the way boxes.py's per-edge groups are collapsed.
ADVANCED_GROUPS = {"advanced", "tuning", "expert"}
DEFAULT_GROUP = "Parameters"


def normalize(dump):
    """dump: parsed --export-format=param JSON. -> {"params": [...], "param_groups": [...]}"""
    # TRAP 1: `.get` with a default, because the key is missing (not empty) when there are none.
    raw = dump.get("parameters") or []
    params = [_param(p) for p in raw]
    return {"params": params, "param_groups": _group(params)}


def _param(p):
    initial = p.get("initial")
    out = {
        "name": p.get("name"),
        "type": _type(p, initial),
        "default": _default(p, initial),
        # TRAP 5: no caption key at all when the .scad has no description comment.
        "help": (p.get("caption") or "").strip(),
        "group": (p.get("group") or DEFAULT_GROUP).strip(),
        "choices": None,
        "choice_labels": None,
        "min": _num(p.get("min")),
        "max": _num(p.get("max")),
        "step": _num(p.get("step")),
    }
    if p.get("options"):
        # TRAP 3: options win over `type`. Keep values and labels separate — OpenSCAD's
        # `// [10:S,20:M]` syntax gives a numeric value a human label, and posting the label back
        # would be a type error.
        out["choices"] = [_num(o.get("value")) for o in p["options"]]
        out["choice_labels"] = [str(o.get("name")) for o in p["options"]]
    return out


def _type(p, initial):
    if p.get("options"):
        return "enum"                       # TRAP 3
    if isinstance(initial, list):
        return "vector"                     # TRAP 4 — by VALUE, never by p["type"]
    t = p.get("type")
    if t == "boolean":
        return "bool"
    if t == "string":
        return "str"
    if t == "number":
        # TRAP 2: 4.0 means "4". Treat an integral value with an integral step as an int so the form
        # shows a clean count rather than "4.0".
        return "int" if _is_integral(initial) and _is_integral(p.get("step", 1.0)) else "float"
    return "str"


def _default(p, initial):
    if isinstance(initial, list):
        # A vector is edited as a comma-separated text field; render.py turns it back into "[a,b,c]".
        return ",".join(_fmt(v) for v in initial)
    return _num(initial)


def _is_integral(v):
    return isinstance(v, float) and v.is_integer() or isinstance(v, int) and not isinstance(v, bool)


def _num(v):
    # bool is a subclass of int in Python — check it FIRST or True becomes 1.
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def _fmt(v):
    n = _num(v)
    return str(n)


def _group(params):
    """Group in first-appearance order — the order the .scad declares them, which is the order the
    author meant. dict preserves insertion order in 3.7+."""
    groups = {}
    for p in params:
        groups.setdefault(p["group"], []).append(p)
    return [
        {"title": title, "advanced": title.strip().lower() in ADVANCED_GROUPS, "params": ps}
        for title, ps in groups.items()
    ]
