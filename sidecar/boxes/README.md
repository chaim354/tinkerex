# boxes-sidecar

A small, **GPL-3.0** service that wraps a (forkable) [boxes.py](https://github.com/florianfesti/boxes)
install and exposes a JSON API the Tinkerex app's `Tools::BoxesClient` speaks:

- `GET /generators` — every generator + its typed parameter schema.
- `POST /generate` `{generator, params}` — render a generator to **SVG** bytes.
- `GET /up` — health.

## Licensing (important)

This entire directory is **GPL-3.0** — it imports the GPL `boxes` library, so the wrapper is a
derivative work and carries the same license (`LICENSE`). It ships as a **separate container** and
is invoked **only over HTTP** on an internal network. The permissive Tinkerex Rails app never
imports or links any of this — that arm's-length aggregation is why the app stays permissive
(see CLAUDE.md §9). **Do not import anything under `sidecar/` into `app/`.**

## Running your own fork

Change the `boxes @ git+…` line in `requirements.txt` to your fork's URL/ref. The API wrapper
(`app.py`) needs no change.

## Dev

```sh
python3 -m venv .venv && .venv/bin/pip install -U pip && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest -q
.venv/bin/gunicorn -b 0.0.0.0:8000 -w 2 app:app     # or: flask --app app run
```

SVG generation is pure-Python (boxes' own SVG surface). `pstoedit` (for PS/DXF/gcode) is **not**
installed — this API only exposes SVG.
