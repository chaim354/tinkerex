#!/usr/bin/env python3
"""
Maker Server end-to-end smoke test.

Exercises the THREE layers together over plain HTTP, so it works against a local
dev server or a deployed (Kamal / Unraid) server:

  * auth         - Devise confirmed account + device-LOGIN enrollment (the model that
                   replaced pairing codes), incl. a wrong-password negative check.
  * file/sync    - the device token works against the fs layer; a real file is
                   committed (begin -> upload chunk -> finalize) to get a node_id/version.
  * maker-app    - create an item, ATTACH the synced file by node_id, tag it, read the
                   detail (tags + taggings ids + attachment), filter, enqueue a preview.

Only the Python stdlib is used (no pip install).

Usage
-----
Local dev (boot first):
    ENABLE_TEST_SIGNUP=1 STORAGE_BACKEND=local bin/rails server -p 3001
    # in another terminal, for preview thumbnails to actually render:
    bin/jobs
    SMOKE_USE_TEST_SIGNUP=1 python3 script/maker_smoke.py

Against the deployed Unraid/Kamal box, with a PRE-EXISTING confirmed account
(there is no test-signup seam in a production-like deploy):
    SMOKE_URL=http://192.168.1.95:3000 \
    SMOKE_EMAIL=you@example.com SMOKE_PASSWORD='...' \
        python3 script/maker_smoke.py

Environment
-----------
    SMOKE_URL              base URL              (default http://localhost:3001)
    SMOKE_EMAIL            account email         (default smoke@example.com)
    SMOKE_PASSWORD         account password      (default password123)
    SMOKE_DEVICE           device name to enroll (default smoke-test)
    SMOKE_USE_TEST_SIGNUP  "1" -> create a CONFIRMED account via POST /v1/test/users
                           (dev/test only; the server must run with ENABLE_TEST_SIGNUP).
                           Otherwise the account must already exist AND be confirmed.
    SMOKE_KEEP             "1" -> skip cleanup (leave the created item + file node)

Exit code: 0 if every step passed, 1 otherwise.
"""
import os
import sys
import json
import time
import uuid
import hashlib
import urllib.request as ureq
import urllib.error

BASE = os.environ.get("SMOKE_URL", "http://localhost:3001").rstrip("/")
EMAIL = os.environ.get("SMOKE_EMAIL", "smoke@example.com")
PASSWORD = os.environ.get("SMOKE_PASSWORD", "password123")
DEVICE = os.environ.get("SMOKE_DEVICE", "smoke-test")
USE_SEAM = os.environ.get("SMOKE_USE_TEST_SIGNUP") == "1"
KEEP = os.environ.get("SMOKE_KEEP") == "1"

_passed = 0
_failed = 0


def http(method, path, data=None, token=None, raw=None, raw_no_ctype=False):
    """Minimal HTTP. Returns (status, body_bytes). status 0 on a transport error."""
    url = path if path.startswith("http") else BASE + path
    headers = {}
    body = None
    if raw is not None:
        body = raw
        if not raw_no_ctype:
            headers["Content-Type"] = "application/octet-stream"
    elif data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = ureq.Request(url, data=body, method=method, headers=headers)
    try:
        resp = ureq.urlopen(req, timeout=30)
        return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # noqa: BLE001 - report any transport error as a failure
        return 0, str(e).encode()


def check(label, status, body, expect):
    global _passed, _failed
    allowed = expect if isinstance(expect, (list, tuple)) else [expect]
    ok = status in allowed
    if ok:
        _passed += 1
    else:
        _failed += 1
    snippet = body[:160].decode("utf-8", "replace") if isinstance(body, bytes) else str(body)[:160]
    print(f"{'PASS' if ok else 'FAIL'} [{status}] {label}\n     {snippet}")
    return body


def jget(body, *keys):
    value = json.loads(body)
    for key in keys:
        value = value[key]
    return value


def main():
    print(f"== Maker smoke vs {BASE}  (account={EMAIL}, test-signup={'on' if USE_SEAM else 'off'}) ==")

    # 1. a confirmed account
    if USE_SEAM:
        check("POST /v1/test/users (confirmed account via seam)",
              *http("POST", "/v1/test/users", {"email": EMAIL, "password": PASSWORD}), [200, 201])
    else:
        print("INFO using a pre-existing confirmed account (no test-signup seam)")

    # 2. device-login enrollment (replaces the old pairing-code flow)
    body = check("POST /v1/devices/login (device enrollment)",
                 *http("POST", "/v1/devices/login",
                       {"email": EMAIL, "password": PASSWORD, "device_name": DEVICE}), 201)
    token = jget(body, "device_token")

    # 2b. negative: a wrong password is a generic 401 (no account enumeration)
    check("POST /v1/devices/login (wrong password -> 401, no enumeration)",
          *http("POST", "/v1/devices/login",
                {"email": EMAIL, "password": PASSWORD + "x", "device_name": DEVICE}), 401)

    # 3. the device token works against the file/sync layer
    check("GET /v1/tree (fs layer with the device token)", *http("GET", "/v1/tree", token=token), 200)

    # 4. commit a real SVG file through the fs layer (begin -> upload -> finalize)
    svg = (b'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="16">'
           b'<rect width="24" height="16" fill="#0a0"/></svg>')
    chunk_hash = hashlib.sha256(svg).hexdigest()
    node_id = str(uuid.uuid4())
    commit_id = str(uuid.uuid4())
    body = check("POST /v1/commit (begin)",
                 *http("POST", "/v1/commit",
                       {"commit_id": commit_id, "node_id": node_id, "parent_node_id": None,
                        "name": "smoke-logo.svg", "base_version_id": None, "size": len(svg),
                        "manifest": [{"hash": chunk_hash, "offset": 0, "length": len(svg)}]},
                       token=token), 200)
    put_urls = jget(body, "put_urls")
    if chunk_hash in put_urls:  # absent if the chunk already exists (dedup) - then skip upload
        # No explicit Content-Type: a SigV4 presigned PUT may not sign that header.
        check("PUT chunk bytes to the presigned URL",
              *http("PUT", put_urls[chunk_hash], raw=svg, raw_no_ctype=True), [200, 201, 204])
    body = check("POST /v1/commit/:id/finalize",
                 *http("POST", f"/v1/commit/{commit_id}/finalize", {}, token=token), 200)
    version_id = jget(body, "version_id")

    # 5. a maker catalog item
    body = check("POST /v1/maker/items",
                 *http("POST", "/v1/maker/items",
                       {"item": {"title": "Smoke Logo", "item_type": "other", "origin": "self_made"}},
                       token=token), 201)
    item_id = jget(body, "id")

    # 6. attach the synced file by node_id (the maker <-> fs seam)
    check("POST attach file_attachment by node_id",
          *http("POST", f"/v1/maker/items/{item_id}/file_attachments",
                {"file_attachment": {"node_id": node_id, "version_id": version_id,
                                     "role": "model", "label": "smoke-logo.svg"}}, token=token), 201)

    # 7. tag the item
    check("POST taggings (tag the item)",
          *http("POST", f"/v1/maker/items/{item_id}/taggings", {"name": "smoke"}, token=token), 201)

    # 8. detail exposes tags + taggings (with ids, so the UI can remove them) + the attachment
    detail_body = http("GET", f"/v1/maker/items/{item_id}", token=token)[1]
    detail = json.loads(detail_body)
    good = (bool(detail.get("tags"))
            and detail.get("taggings")
            and detail["taggings"][0].get("id")
            and detail.get("file_attachments"))
    check("GET item detail exposes tags + taggings ids + attachment", 200 if good else 0, detail_body, 200)

    # 9. text filter
    check("GET /v1/maker/items?q=smoke (text filter)",
          *http("GET", "/v1/maker/items?q=smoke", token=token), 200)

    # 10. enqueue a preview, then briefly poll for it to render.
    # `filename` is what lets the job pick a renderer (the record is keyed by node_id, a
    # UUID with no extension) - the UI passes the attached file's name the same way.
    check("POST /v1/maker/previews (enqueue thumbnail)",
          *http("POST", "/v1/maker/previews",
                {"node_id": node_id, "version_id": version_id, "kind": "thumbnail",
                 "filename": "smoke-logo.svg"}, token=token), [200, 201])
    status = "?"
    for _ in range(10):
        _, preview_body = http("GET", f"/v1/maker/previews?node_id={node_id}&version_id={version_id}", token=token)
        try:
            parsed = json.loads(preview_body)
            rows = parsed.get("previews", parsed) if isinstance(parsed, dict) else parsed
            status = (rows[0] if rows else {}).get("status", "?")
        except Exception:  # noqa: BLE001
            status = "?"
        if status in ("ready", "failed", "unsupported"):
            break
        time.sleep(1)
    print(f"INFO preview status after poll: {status}  "
          f"(ready needs a running job worker + a cross-process chunk store; "
          f"the SVG renderer emits image/svg+xml)")

    # cleanup (best effort) so repeated runs against a real server don't pile up
    if not KEEP:
        http("DELETE", f"/v1/maker/items/{item_id}", token=token)
        http("DELETE", f"/v1/nodes/{node_id}", token=token)
        print("INFO cleaned up the smoke item + file node")

    print(f"\n== {_passed} passed, {_failed} failed ==")
    sys.exit(1 if _failed else 0)


if __name__ == "__main__":
    main()
