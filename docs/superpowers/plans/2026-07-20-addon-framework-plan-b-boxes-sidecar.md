# Addon Framework — Plan B (the Boxes Python sidecar + real wiring + deploy)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stand up the **forked `boxes.py`** as a **GPL-isolated Python sidecar** exposing the JSON API the (already-built) `BoxesClient` speaks — `GET /generators`, `POST /generate`, `GET /up` — then deploy it as an internal-only Kamal accessory and wire `BOXES_SIDECAR_URL` so the Box Generator addon becomes live.

**Architecture:** A small **Flask** app (`sidecar/boxes/app.py`) imports the boxes library, introspects each generator's `argparser` for the param schema, and renders a generator to SVG bytes in-memory (`box_cls() → parseArgs(["--format","svg", …]) → open() → render() → close()`). Served by **gunicorn** in a `python:3.12-slim` container. Rails talks to it over the internal Kamal network via `BoxesClient` (Plan A). The sidecar is a **separate artifact with its own GPL-3.0 LICENSE**; nothing links it into the permissive Rails app (§9 aggregation).

**Tech Stack:** Python 3.12, Flask, gunicorn, `boxes` (from git, pinned/forkable), Docker, Kamal accessory.

**Spec:** `docs/superpowers/specs/2026-07-20-addon-framework-boxes-design.md` (§6, §7). **Depends on Plan A** (merged): `BoxesClient` + `FakeBoxes` + the Boxes addon UI already exist and go live the moment `BOXES_SIDECAR_URL` is set.

**Licensing (§9):** boxes.py is **GPL-3.0**. The entire `sidecar/boxes/` tree — the vendored/installed boxes AND our wrapper that imports it — is GPL and carries its own `LICENSE`. It ships as a **distinct container** invoked only over HTTP. The permissive Rails app never imports or links it. Do not import anything from `sidecar/` into `app/`.

**"Fork" posture:** v1 installs boxes from a **pinned git ref** (`BOXES_GIT_REF`, default upstream `florianfesti/boxes`). To run the user's fork, repoint the git URL/ref — no wrapper change. (A submodule is an option later; the pinned-git install keeps v1 simple while remaining forkable.)

---

## Task 1: Sidecar skeleton (Flask app + /up) + local venv

**Files:**
- Create: `sidecar/boxes/app.py`, `sidecar/boxes/requirements.txt`, `sidecar/boxes/LICENSE` (GPL-3.0), `sidecar/boxes/README.md`, `sidecar/boxes/tests/test_api.py`, `sidecar/boxes/pytest.ini`

- [ ] **Step 1: requirements + LICENSE + README**

`sidecar/boxes/requirements.txt`:
```
flask==3.0.*
gunicorn==22.0.*
boxes @ git+https://github.com/florianfesti/boxes.git@<PINNED_COMMIT_SHA>
```
Pin `<PINNED_COMMIT_SHA>` to a current `florianfesti/boxes` commit (record which). `sidecar/boxes/LICENSE` = the GPL-3.0 text (boxes' license). `sidecar/boxes/README.md`: state that this tree is GPL-3.0 (it imports boxes), runs as an isolated internal-only sidecar, and is invoked by Rails only over HTTP; to use a fork, change the boxes git URL in `requirements.txt`.

- [ ] **Step 2: Create a local venv and install (dev)**

Run:
```
cd sidecar/boxes && python3 -m venv .venv && .venv/bin/pip install -U pip && .venv/bin/pip install -r requirements.txt
```
Expected: installs flask, gunicorn, boxes. Confirm: `.venv/bin/python -c "import boxes, boxes.generators; print(len(boxes.generators.getAllBoxGenerators()))"` prints a count (>100).

- [ ] **Step 3: Write the failing test**

```python
# sidecar/boxes/tests/test_api.py
import json
from app import app

def client():
    app.config.update(TESTING=True)
    return app.test_client()

def test_up():
    r = client().get("/up")
    assert r.status_code == 200
```

- [ ] **Step 4: Run it (fails — no app)**

Run: `cd sidecar/boxes && .venv/bin/python -m pytest -q`
Expected: FAIL (import error).

- [ ] **Step 5: Minimal app**

```python
# sidecar/boxes/app.py
# GPL-3.0 (imports the GPL boxes library). Runs as an isolated sidecar; Rails calls it over HTTP.
from flask import Flask, request, jsonify, Response

app = Flask(__name__)

@app.get("/up")
def up():
    return "ok", 200
```

- [ ] **Step 6: Run it (passes)**

Run: `cd sidecar/boxes && .venv/bin/python -m pytest -q`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add sidecar/boxes/requirements.txt sidecar/boxes/LICENSE sidecar/boxes/README.md sidecar/boxes/app.py sidecar/boxes/tests/test_api.py
git commit -m "feat(boxes-sidecar): Flask skeleton + /up (GPL-isolated)"
```

Note: add `sidecar/boxes/.venv/` to `.gitignore`.

---

## Task 2: `GET /generators` — the param schema

**Files:** Modify `sidecar/boxes/app.py`; extend `tests/test_api.py`.

- [ ] **Step 1: Write the failing test**

```python
def test_generators_shape():
    data = client().get("/generators").get_json()
    assert isinstance(data, list) and len(data) > 50
    g = next(x for x in data if x["key"] == "ABox")     # a simple fully-closed box
    assert g["title"] and isinstance(g["params"], list)
    names = {p["name"] for p in g["params"]}
    assert {"x", "y", "h"} <= names                      # ABox has x/y/h
    xp = next(p for p in g["params"] if p["name"] == "x")
    assert xp["type"] in ("float", "int") and xp["default"] is not None
```

- [ ] **Step 2: Run it (fails)**

Run: `cd sidecar/boxes && .venv/bin/python -m pytest -q -k generators`
Expected: FAIL (404).

- [ ] **Step 3: Implement `/generators` (argparser introspection)**

Add to `app.py`:

```python
import argparse
import boxes
import boxes.generators

# Base args that are transport/internal, not design params — hidden from the schema.
SKIP = {"help", "format", "output", "input", "quiet", "debug"}

def _all_generators():
    # {"ABox": <class ABox>, ...} — strip the module path boxes uses as the dict key.
    out = {}
    for full, cls in boxes.generators.getAllBoxGenerators().items():
        out[full.split(".")[-1]] = cls
    return out

def _param_type(action):
    t = action.type
    if action.choices:
        return "enum"
    if t is float:
        return "float"
    if t is int:
        return "int"
    # boxes uses a BoolArg type for toggles; detect by name so "--flag true/false" works.
    if getattr(t, "__name__", type(t).__name__) in ("BoolArg", "bool"):
        return "bool"
    if isinstance(action, argparse._StoreTrueAction):
        return "bool"
    return "str"

def _params_for(cls):
    box = cls()  # instantiating builds its argparser
    params = []
    for a in box.argparser._actions:
        if a.dest in SKIP or isinstance(a, argparse._HelpAction):
            continue
        params.append({
            "name": a.dest,
            "type": _param_type(a),
            "default": a.default,
            "help": (a.help or "").strip(),
            "choices": list(a.choices) if a.choices else None,
        })
    return params

@app.get("/generators")
def generators():
    out = []
    for key, cls in sorted(_all_generators().items()):
        try:
            out.append({"key": key, "title": (cls.__doc__ or key).strip().split("\n")[0],
                        "group": getattr(cls, "webinterface", "Boxes"), "params": _params_for(cls)})
        except Exception:
            # A generator that can't introspect (rare) is skipped rather than 500-ing the list.
            continue
    return jsonify(out)
```

Note: verify against the installed boxes — `cls.__doc__` for the title and the `webinterface`/group attribute name may differ; adjust to whatever the installed version exposes (the test only pins `title` non-empty + `params` shape).

- [ ] **Step 4: Run it (passes)**

Run: `cd sidecar/boxes && .venv/bin/python -m pytest -q -k generators`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add sidecar/boxes/app.py sidecar/boxes/tests/test_api.py
git commit -m "feat(boxes-sidecar): GET /generators — param schema from argparser"
```

---

## Task 3: `POST /generate` — render SVG

**Files:** Modify `sidecar/boxes/app.py`; extend `tests/test_api.py`.

- [ ] **Step 1: Write the failing test**

```python
def test_generate_returns_svg():
    r = client().post("/generate", json={"generator": "ABox", "params": {"x": 80, "y": 40, "h": 30}})
    assert r.status_code == 200
    assert r.mimetype == "image/svg+xml"
    assert r.data[:5] == b"<?xml" or b"<svg" in r.data[:400]

def test_generate_bad_generator_is_404():
    assert client().post("/generate", json={"generator": "NopeNope", "params": {}}).status_code == 404

def test_generate_bad_params_is_422():
    r = client().post("/generate", json={"generator": "ABox", "params": {"x": "not-a-number"}})
    assert r.status_code == 422
```

- [ ] **Step 2: Run it (fails)**

Run: `cd sidecar/boxes && .venv/bin/python -m pytest -q -k generate`
Expected: FAIL.

- [ ] **Step 3: Implement `/generate`**

Add to `app.py`:

```python
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
        # argparse calls sys.exit() on a bad value; turn that into a 422 instead of killing the worker.
        box.parseArgs(_argv(body.get("params")))
        box.open()
        box.render()
        data = box.close()
    except SystemExit:
        return jsonify({"error": "invalid parameters"}), 422
    except Exception as e:  # a generator-internal error (e.g. impossible geometry) -> 422, not 500
        return jsonify({"error": f"generation failed: {e}"}), 422
    return Response(data, mimetype="image/svg+xml")
```

Note: confirm `box.close()` returns SVG **bytes** with the installed boxes (boxesserver relies on `self.output` being a BytesIO and `close()` returning its bytes). If a version returns something else, capture `box.output.getvalue()` after `close()`. The test pins the wire result (SVG bytes), so reconcile there.

- [ ] **Step 4: Run it (passes)**

Run: `cd sidecar/boxes && .venv/bin/python -m pytest -q`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add sidecar/boxes/app.py sidecar/boxes/tests/test_api.py
git commit -m "feat(boxes-sidecar): POST /generate — render SVG, 404/422 on bad input"
```

---

## Task 4: Dockerfile + container smoke

**Files:** Create `sidecar/boxes/Dockerfile`, `sidecar/boxes/.dockerignore`.

- [ ] **Step 1: Dockerfile**

```dockerfile
# sidecar/boxes/Dockerfile — GPL-3.0 image (imports boxes). Internal-only; Rails calls it over HTTP.
FROM python:3.12-slim
WORKDIR /app

# SVG generation is pure-Python (boxes' own SVG surface); pstoedit is only needed for PS/DXF/gcode
# output, which this API does not expose. Kept out to stay slim. Add it only if you expose those.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./
EXPOSE 8000
# 2 workers is plenty for one user; a generate call is CPU-bound and short. Bind on all interfaces
# (the Kamal network); never published to the host/internet (Task 5).
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--timeout", "60", "app:app"]
```

`.dockerignore`: `.venv`, `tests`, `__pycache__`.

- [ ] **Step 2: Build + smoke the container**

Run: `docker build -t boxes-sidecar-check sidecar/boxes`
Run: `docker run -d --name bsc -p 18000:8000 boxes-sidecar-check && sleep 3`
Run: `curl -s localhost:18000/up` → `ok`
Run: `curl -s localhost:18000/generators | head -c 120` → a JSON array
Run: `curl -s -X POST localhost:18000/generate -H 'content-type: application/json' -d '{"generator":"ABox","params":{"x":80,"y":40,"h":30}}' | head -c 80` → SVG
Then: `docker rm -f bsc`
Expected: all three respond correctly. (If boxes needs a system lib at import time, add it to the Dockerfile and rebuild — SVG-only should not.)

- [ ] **Step 3: Commit**

```bash
git add sidecar/boxes/Dockerfile sidecar/boxes/.dockerignore
git commit -m "build(boxes-sidecar): Dockerfile (slim, SVG-only, gunicorn)"
```

---

## Task 5: Deploy — Kamal accessory + `BOXES_SIDECAR_URL`

**Files:** Modify `config/deploy.yml` (+ `deploy.s3.yml`, `deploy.share.yml`), `.github/workflows/ci.yml` (optional health check), `docs/DEPLOY.md`.

- [ ] **Step 1: Add the accessory to `config/deploy.yml`**

```yaml
accessories:
  boxes:
    image: ghcr.io/chaim354/boxes-sidecar:latest
    host: 192.168.1.95
    # NO `port:` mapping — internal only, reachable on the Kamal network as `tinkerex-boxes`.
    roles:
      - web
```

Add to the app's `env.clear` (each deploy that should have Boxes — at least share, the real library):
```yaml
    BOXES_SIDECAR_URL: http://tinkerex-boxes:8000
```
(Confirm the accessory's on-network hostname Kamal assigns — `kamal accessory boot boxes` then `docker network inspect kamal`; it is typically `<service>-<accessory>`. Set `BOXES_SIDECAR_URL` to match.)

- [ ] **Step 2: Build + push the sidecar image**

The sidecar is built/pushed separately from the app (different Dockerfile). Add a one-liner (or a `bin/` script): build `sidecar/boxes` for `linux/amd64`, tag `ghcr.io/chaim354/boxes-sidecar:latest`, push. Reuse the registry login the app deploy uses (`KAMAL_REGISTRY_PASSWORD`). Document it in `docs/DEPLOY.md`.

- [ ] **Step 3: CI health check (self-hosted, optional but recommended)**

Add a `boxes-sidecar` job to `ci.yml` (self-hosted linux): build the sidecar image, run it, `curl /up` + a `/generate` smoke, tear down. Idempotent; self-hosted only (§15).

- [ ] **Step 4: Commit**

```bash
git add config/deploy.yml config/deploy.s3.yml config/deploy.share.yml .github/workflows/ci.yml docs/DEPLOY.md
git commit -m "deploy(boxes-sidecar): Kamal accessory + BOXES_SIDECAR_URL"
```

---

## Task 6: Rails real-sidecar smoke + go live

- [ ] **Step 1: Rails-side real-sidecar integration smoke (skips without a sidecar)**

Create `test/integration/tools/boxes_live_test.rb`: if `ENV["BOXES_SIDECAR_URL"]` is set, drive `BoxesClient.current` (no stub) — `generators` returns a non-empty list including a known generator; `generate` returns SVG bytes. Skip cleanly when unset (mirrors the sync-engine "skips with no server" pattern). This exercises the real HTTP client against a real sidecar.

Run locally against the Task 4 container:
```
docker run -d --name bsc -p 18000:8000 boxes-sidecar-check
BOXES_SIDECAR_URL=http://localhost:18000 bin/rails test test/integration/tools/boxes_live_test.rb
docker rm -f bsc
```
Expected: PASS.

- [ ] **Step 2: Deploy the sidecar + app**

Build/push the sidecar image (Task 5 step 2). `kamal accessory boot boxes` (or `kamal deploy` if the accessory boots with it). Redeploy the app leg(s) that got `BOXES_SIDECAR_URL` (at least `-d share`). Secrets via 1Password as usual (`op read op://Personal/ghcr.io/password`, `op://Personal/seaweednew/secret key`), with the empty-secret guard.

- [ ] **Step 3: Verify live**

- `docker ps` on the box shows `tinkerex-boxes` (the accessory) running.
- From the app container: `curl -s http://tinkerex-boxes:8000/up` → `ok`.
- In the browser: `/tools` now shows Box Generator as **available**; pick a generator → form → Preview shows a real box → Save → the bundle (SVG + params) lands in the library, the SVG with a thumbnail.

- [ ] **Step 4: STATUS + spec**

Update `docs/STATUS.md`: Plan B live — the Box Generator is functional against the forked boxes sidecar. Note the sidecar is GPL-isolated (own image + LICENSE, internal-only). Commit.

---

## Self-review notes (author)

- **Spec coverage:** §6 sidecar deployment → Tasks 4–5; §7 sidecar API (`/generators`, `/generate`, `/up`) → Tasks 1–3; real client wiring → Task 6 (BoxesClient already built in Plan A).
- **Verify against the installed boxes when implementing:** the `webinterface`/group attribute name and title source (Task 2); that `box.close()` returns SVG bytes vs. reading `box.output` (Task 3); the Kamal accessory on-network hostname for `BOXES_SIDECAR_URL` (Task 5). Each step says to reconcile with reality.
- **Licensing:** the entire `sidecar/boxes/` tree is GPL-3.0 with its own LICENSE, a separate image, internal-only, invoked over HTTP — never imported into `app/`. Keep it that way.
- **Type consistency:** the sidecar's `/generators` element (`{key, title, group, params:[{name,type,default,help,choices}]}`) and `/generate` (`{generator, params}` → SVG bytes) match `BoxesClient::Generator` / `BoxesClient#generate` from Plan A exactly.
```
