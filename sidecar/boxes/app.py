# boxes-sidecar — GPL-3.0 (imports the GPL `boxes` library; see LICENSE / README).
#
# A thin JSON API over boxes.py: list generators + their parameter schemas, and render a generator
# to SVG. Runs as an isolated internal-only sidecar; the Tinkerex Rails app calls it over HTTP and
# never imports this code.
import argparse
import os
import re

import boxes
import boxes.generators
from flask import Flask, request, jsonify, Response, send_file

app = Flask(__name__)

# boxes.py's gallery sample photos, bundled into this image by the Dockerfile as <Class>-thumb.jpg.
SAMPLES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples")

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


def _multiline(a):
    # boxes.py's own web UI renders a str param as a <textarea> exactly when its default carries a
    # newline (see boxesserver.arg2html). Mirror that RULE rather than naming params: it covers
    # TrayLayout/GridfinityTrayLayout's `layout`, Desksign's `label`, FrontPanel's `layout` and
    # NightLightBox's `BackExtraHoles` — and any future one — for free.
    #
    # This is not cosmetic. An <input type="text"> runs HTML's value sanitization algorithm, which
    # STRIPS line breaks, so every one of those params arrived here with its newlines silently
    # deleted: TrayLayout 422'd, FrontPanel 422'd, NightLightBox 422'd, and Desksign quietly dropped
    # the second line of the sign.
    return a.type is str and isinstance(a.default, str) and "\n" in a.default


def _seeded_default(box, a):
    """A BLANK multiline default is a marker, not a value — hand the form a real starting layout.

    boxes.py gives TrayLayout and GridfinityTrayLayout a `layout` default of "\\n". That newline is
    there ONLY to trip the textarea rule above; it is not a layout. Submitted verbatim it fails with
    "Need more than one wall in x direction", and stripped to "" it fails with "traylayout requires
    --layout, --input, or implementation of generate_layout" unless the generator happens to have a
    generate_layout() fallback (GridfinityTrayLayout does, TrayLayout does not). Either way the user
    meets an error before they have touched anything.

    So build a starting layout with boxes.py's OWN code, which makes it parseable by construction:
    the generator's generate_layout() where it has one, else TrayLayoutFile — the class boxes.py
    ships for exactly this job (it is step 1 of the two-step flow, and its __str__ IS the format).

    Upstream instead seeds the textarea from JavaScript on page load. Doing it here means the form
    works with no JS at all, and the keep-in-sync-with-sx/sy JS is polish rather than load-bearing.
    """
    if a.default.strip():
        return a.default  # a real multiline default (Desksign's label, FrontPanel's layout) — leave it
    try:
        if callable(getattr(box, "generate_layout", None)):
            fresh = type(box)()
            fresh.parseArgs([])
            return fresh.generate_layout()

        # TrayLayout-shaped: the compartment sizes live in sx/sy, and TrayLayoutFile draws them.
        sizes = {x.dest: x.default for g in box.argparser._action_groups for x in g._group_actions}
        tray_layout_file = _all_generators().get("TrayLayoutFile")
        if tray_layout_file is None or "sx" not in sizes or "sy" not in sizes:
            return a.default
        f = tray_layout_file()
        f.parseArgs(["--sx", str(sizes["sx"]), "--sy", str(sizes["sy"])])
        f.render()
        return f.close().getvalue().decode()
    except Exception:
        # Never let seeding break /generators — a blank layout is the status quo, not a regression.
        return a.default


def _param(a, box):
    multiline = _multiline(a)
    return {
        "name": a.dest,
        "type": _param_type(a),
        "default": _seeded_default(box, a) if multiline else a.default,
        "help": (a.help or "").strip(),
        "choices": list(a.choices) if a.choices else None,
        # Consumed by the form to pick <textarea> over <input type="text">. Additive: an app that
        # predates this key just reads it as falsy and renders what it rendered before, so the
        # sidecar and the app can deploy in either order.
        "multiline": multiline,
    }


def _param_groups_for(cls):
    # boxes.py organises each generator's argparser into titled groups: the generator's own settings,
    # "Default Settings", then one "Settings for <edge/part>" group per used edge (Finger Joints, Lid,
    # …). Preserve that grouping so the UI can render sections like boxes.py's own web form.
    box = cls()  # instantiating builds its argparser
    groups = []
    for g in box.argparser._action_groups:
        params = [
            _param(a, box) for a in g._group_actions
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


@app.get("/sample/<name>")
def sample(name):
    # `name` is a generator class name (== the sample filename stem). Reject anything else so a crafted
    # value can't escape SAMPLES_DIR; a name with a "/" never reaches here (Flask routes one segment).
    # Missing sample -> 404 (most generators have none; the tile falls back to text).
    if not re.fullmatch(r"[A-Za-z0-9]+", name or ""):
        return "", 404
    path = os.path.join(SAMPLES_DIR, f"{name}-thumb.jpg")
    if not os.path.isfile(path):
        return "", 404
    return send_file(path, mimetype="image/jpeg", max_age=2592000)


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
