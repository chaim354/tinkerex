# boxes-sidecar — GPL-3.0 (imports the GPL `boxes` library; see LICENSE / README).
#
# A thin JSON API over boxes.py: list generators + their parameter schemas, and render a generator
# to SVG. Runs as an isolated internal-only sidecar; the Tinkerex Rails app calls it over HTTP and
# never imports this code.
import argparse
import re

import boxes
import boxes.generators
from flask import Flask, request, jsonify, Response

app = Flask(__name__)

# Transport/internal base args — never design params. `format` is forced to svg by this sidecar and
# `output`/`input`/`quiet`/`debug` are plumbing, so they stay hidden from the form.
SKIP = {"help", "format", "output", "input", "quiet", "debug"}
# A setting GROUP is "advanced" when every one of its params is a per-edge/part tuning knob — dest
# like FingerJoint_style, Lid_handle, Mounting_*. The form still shows these (matching boxes.py's own
# web UI) but collapses them so the common dimensions stay front and centre.
ADVANCED = re.compile(r"^[A-Z][A-Za-z0-9]*_")


def _all_generators():
    # {"ABox": <class>, ...} — boxes keys by full module path; we expose the class name.
    return {full.split(".")[-1]: cls for full, cls in boxes.generators.getAllBoxGenerators().items()}


def _param_type(action):
    t = action.type
    if action.choices:
        return "enum"
    if t is float:
        return "float"
    if t is int:
        return "int"
    # boxes uses a BoolArg type for toggles (default-able, "--flag true/false").
    if getattr(t, "__name__", type(t).__name__) in ("BoolArg", "bool"):
        return "bool"
    if isinstance(action, argparse._StoreTrueAction):
        return "bool"
    return "str"


def _param(a):
    return {
        "name": a.dest,
        "type": _param_type(a),
        "default": a.default,
        "help": (a.help or "").strip(),
        "choices": list(a.choices) if a.choices else None,
    }


def _param_groups_for(cls):
    # boxes.py organises each generator's argparser into titled groups: the generator's own settings,
    # "Default Settings", then one "Settings for <edge/part>" group per used edge (Finger Joints, Lid,
    # …). Preserve that grouping so the UI can render sections like boxes.py's own web form.
    box = cls()  # instantiating builds its argparser
    groups = []
    for g in box.argparser._action_groups:
        params = [
            _param(a) for a in g._group_actions
            if not isinstance(a, argparse._HelpAction) and a.dest not in SKIP
        ]
        if not params:
            continue
        groups.append({
            "title": (g.title or "Settings").strip(),
            "advanced": all(ADVANCED.match(p["name"]) for p in params),
            "params": params,
        })
    return groups


@app.get("/up")
def up():
    return "ok", 200


def _argv(params):
    argv = ["--format", "svg"]
    for k, v in (params or {}).items():
        if isinstance(v, bool):
            v = "true" if v else "false"
        argv += [f"--{k}", str(v)]
    return argv


@app.post("/generate")
def generate():
    body = request.get_json(force=True, silent=True) or {}
    cls = _all_generators().get(body.get("generator"))
    if cls is None:
        return jsonify({"error": "unknown generator"}), 404
    try:
        box = cls()
        # argparse calls sys.exit() on a bad value -> SystemExit; turn that into a 422 instead of
        # killing the worker. `close()` returns a BytesIO in this boxes version.
        box.parseArgs(_argv(body.get("params")))
        box.open()
        box.render()
        raw = box.close()
        svg = raw.getvalue() if hasattr(raw, "getvalue") else raw
    except SystemExit:
        return jsonify({"error": "invalid parameters"}), 422
    except Exception as e:  # generator-internal error (impossible geometry, etc.) -> 422, not 500
        return jsonify({"error": f"generation failed: {e}"}), 422
    return Response(svg, mimetype="image/svg+xml")


@app.get("/generators")
def generators():
    out = []
    for key, cls in sorted(_all_generators().items()):
        try:
            grps = _param_groups_for(cls)
            out.append({
                "key": key,
                "title": (cls.__doc__ or key).strip().split("\n")[0],
                "group": getattr(cls, "ui_group", "Misc") or "Misc",
                "param_groups": grps,
                # Back-compat: a previously-deployed app read a flat `params` (basic params only).
                # Emitting it too lets this sidecar deploy before/after the app without a break window.
                # Safe to drop once every app consumes `param_groups`.
                "params": [p for g in grps if not g["advanced"] for p in g["params"]],
            })
        except Exception:
            # A generator that can't introspect (rare) is skipped, not a 500 for the whole list.
            continue
    return jsonify(out)
