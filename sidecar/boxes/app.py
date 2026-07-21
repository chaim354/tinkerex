# boxes-sidecar — GPL-3.0 (imports the GPL `boxes` library; see LICENSE / README).
#
# A thin JSON API over boxes.py: list generators + their parameter schemas, and render a generator
# to SVG. Runs as an isolated internal-only sidecar; the Tinkerex Rails app calls it over HTTP and
# never imports this code.
from flask import Flask, request, jsonify, Response

app = Flask(__name__)


@app.get("/up")
def up():
    return "ok", 200
