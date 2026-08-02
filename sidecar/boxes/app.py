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


class ParamError(Exception):
    """A parameter this API will not forward, or one argparse rejected -> a 422 that NAMES it."""


def _offered(cls):
    """Does this API offer `cls` at all? Mirrors boxes.py's OWN `webinterface` flag.

    Upstream sets `webinterface = False` on the generators its own web UI excludes, and mirroring
    that RULE (rather than keeping our own list of names) is the same move `_multiline` makes for the
    textarea rule: a boxes.py bump cannot silently outgrow it. It marks four here, each independently
    confirmed wrong for this surface:

      * Edges          — render() only PRINTS the edge catalogue to stdout and draws nothing, so it
                         answered 200 image/svg+xml with a ZERO-BYTE body. Saving that writes an
                         empty .svg into the user's library.
      * TrayLayoutFile — emits an ASCII layout ("+-+-+-+"), not SVG, and its parser has no --format
                         at all. It is step 1 of boxes.py's two-step CLI flow, and this sidecar
                         already runs it INTERNALLY to seed TrayLayout's textarea.
      * JigsawPuzzle   — upstream's own docstring says "Still alpha".
      * Lamp           — no docstring (the tile would be titled from the bare key) and a 484 KB render.

    This gates the API BOUNDARY only. `_all_generators()` still returns them, which is exactly what
    `_seeded_default` relies on when it drives TrayLayoutFile to build TrayLayout's starting layout.
    """
    return getattr(cls, "webinterface", True)


def _all_generators():
    # {"ABox": <class>, ...} — boxes keys by full module path; we expose the class name.
    return {full.split(".")[-1]: cls for full, cls in boxes.generators.getAllBoxGenerators().items()}


def _actions(box):
    """Every option this generator's argparser REGISTERED, keyed by dest.

    A `dest` IS NOT A FLAG. boxes.py declares five params whose dest differs from their option
    string — FlexBox3 `--c`/dest `d`, CompartmentBox `--margin_t`/`margin_vertical` and
    `--margin_s`/`margin_side`, TypeTray `--gripheight`/`gh` and `--gripwidth`/`gw` — so an argv
    built as "--" + dest names a DIFFERENT argument. That failed two ways, and the quiet one is worse:

      * no such option -> argparse "unrecognized arguments" -> the generator 422'd for every user on
        every render (CompartmentBox, TypeTray);
      * the invented flag is a unique PREFIX of a real one, so argparse ABBREVIATION-matched it —
        FlexBox3's `--d` resolved to `--debug`, the user's value disappeared into a plumbing flag,
        and the box came back 200 drawn at the default. No error, anywhere, ever.

    Everything that goes out on the wire is built from this map, so neither can recur.
    """
    return {a.dest: a
            for g in box.argparser._action_groups
            for a in g._group_actions
            if not isinstance(a, argparse._HelpAction)}


def _exposed(box):
    """The params we advertise in /generators AND accept in /generate — ONE definition for both.

    The entire bug above lived in the gap between "what the form renders" and "what we then send", so
    those two must not be derived separately.

    FileType params are dropped by RULE rather than by name (as `_multiline` mirrors boxes.py's
    textarea rule): such a param names a path on THIS container's filesystem, which a browser client
    can never place a file at — a field that cannot work, and a server-side open() primitive with no
    reason to exist. The only instance here, TypeTray's `label_file`, is upstream-broken anyway:
    typetray.py:119 has argparse open it while :247 does `Path(self.label_file).open()`, so any real
    path raises TypeError and its empty default makes argparse try to open ''.
    """
    return {d: a for d, a in _actions(box).items()
            if d not in SKIP and a.option_strings and not isinstance(a.type, argparse.FileType)}


def _flag(action):
    # The option string argparse actually registered — never "--" + dest. See _actions().
    longs = [o for o in action.option_strings if o.startswith("--")]
    return longs[0] if longs else action.option_strings[0]


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
    exposed = _exposed(box)  # the SAME set /generate will accept — see _exposed()
    groups = []
    for g in box.argparser._action_groups:
        params = [_param(a, box) for a in g._group_actions if a.dest in exposed]
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


def _argv(box, params):
    exposed = _exposed(box)
    known = _actions(box)
    # `--format svg` ONLY where the parser has it. It was prepended unconditionally, which is an
    # argument the sidecar itself invented for TrayLayoutFile, whose parser is just
    # [-h] [--sx] [--sy] [--output]. Kept even though /generate no longer offers that generator:
    # the condition is a property of the PARSER, not of who we happen to expose today, and
    # `_seeded_default` drives TrayLayoutFile internally.
    argv = ["--format", "svg"] if "format" in known else []
    for k, v in (params or {}).items():
        action = exposed.get(k)
        if action is None:
            # Deliberately un-advertised (SKIP / FileType): drop it quietly — a state saved before
            # this change can still carry `label_file: ""`, and refusing would break re-rendering it.
            if k in known:
                continue
            # Genuinely not a param of this generator: refuse BY NAME. Silently dropping it is how a
            # future boxes.py bump would quietly redraw everyone's saved boxes with no way to tell.
            raise ParamError(f"unknown parameter: {k}")
        if v is None:
            continue
        if isinstance(v, bool):
            v = "true" if v else "false"
        argv += [_flag(action), str(v)]
    return argv


def _raise_param_error(message):
    raise ParamError(message)


@app.post("/generate")
def generate():
    body = request.get_json(force=True, silent=True) or {}
    cls = _all_generators().get(body.get("generator"))
    if cls is None or not _offered(cls):
        # Not offered == not generatable. Gating BOTH endpoints on one rule is what stops a hidden
        # generator staying reachable by a direct POST (and answering ASCII as image/svg+xml).
        return jsonify({"error": "unknown generator"}), 404
    try:
        box = cls()
        # argparse writes its message to stderr and calls sys.exit(). Capture the MESSAGE instead by
        # replacing this parser instance's error hook: it names the exact param and reason, and Rails
        # passes the sidecar's body straight to the UI, so this is the difference between a
        # diagnosable error and "invalid parameters". Per-instance rather than redirecting the
        # process's stderr — that swaps a global, which would interleave on threaded workers — and it
        # drops argparse's usage dump and the program name (a gunicorn path) on the floor.
        box.argparser.error = _raise_param_error
        box.parseArgs(_argv(box, body.get("params")))
        box.open()
        box.render()
        raw = box.close()
        svg = raw.getvalue() if hasattr(raw, "getvalue") else raw
    except ParamError as e:
        return jsonify({"error": str(e)}), 422
    except SystemExit:
        # Belt-and-braces: any exit path that did NOT come through argparser.error.
        return jsonify({"error": "invalid parameters"}), 422
    except Exception as e:  # generator-internal error (impossible geometry, etc.) -> 422, not 500
        return jsonify({"error": f"generation failed: {e}"}), 422
    return Response(svg, mimetype="image/svg+xml")


@app.get("/generators")
def generators():
    out = []
    for key, cls in sorted(_all_generators().items()):
        if not _offered(cls):
            continue
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
