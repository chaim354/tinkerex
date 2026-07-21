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

# Transport/internal base args — never design params.
SKIP = {"help", "format", "output", "input", "quiet", "debug"}
# Advanced per-edge/part setting groups (e.g. FingerJoint_style, Mounting_*): dozens of tuning
# params with sensible defaults. Hidden from the form to keep it focused on the box's dimensions
# and common options; a later "advanced" toggle can surface them.
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


def _params_for(cls):
    box = cls()  # instantiating builds its argparser
    out = []
    for a in box.argparser._actions:
        if isinstance(a, argparse._HelpAction) or a.dest in SKIP or ADVANCED.match(a.dest):
            continue
        out.append({
            "name": a.dest,
            "type": _param_type(a),
            "default": a.default,
            "help": (a.help or "").strip(),
            "choices": list(a.choices) if a.choices else None,
        })
    return out


@app.get("/up")
def up():
    return "ok", 200


@app.get("/generators")
def generators():
    out = []
    for key, cls in sorted(_all_generators().items()):
        try:
            out.append({
                "key": key,
                "title": (cls.__doc__ or key).strip().split("\n")[0],
                "group": "Boxes",
                "params": _params_for(cls),
            })
        except Exception:
            # A generator that can't introspect (rare) is skipped, not a 500 for the whole list.
            continue
    return jsonify(out)
