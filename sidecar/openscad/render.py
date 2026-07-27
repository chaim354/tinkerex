"""Exec OpenSCAD in a bounded sandbox and cache the result by content.

Spec §7: synchronous, hard 60 s timeout. Spec §10: user-supplied .scad is arbitrary code execution
BY DESIGN (that is what a generator is), so the bound is resource-shaped, not sanitization-shaped —
the sidecar holds no secrets and no user data, and the real risk is a runaway loop DoSing a worker.
"""
import hashlib
import json
import os
import resource
import subprocess
import tempfile
import uuid
from dataclasses import dataclass

# THE DEFAULT IS THE WRAPPER, NOT THE RAW BINARY, and that is deliberate (see the Dockerfile).
# /usr/local/bin/openscad is a one-line script that scopes LD_LIBRARY_PATH=/opt/openscad/usr/lib to
# this one process. Setting that globally instead breaks the image's OWN Python: the AppImage ships
# an older libcrypto.so.3, so _ssl fails to load and every outbound HTTPS call dies — while all six
# OpenSCAD capability assertions stay green. Callers exec OPENSCAD_BIN and inherit nothing special.
# Defaulting to /opt/openscad/usr/bin/openscad here would make a bare host run diverge from the image.
OPENSCAD_BIN = os.environ.get("OPENSCAD_BIN", "/usr/local/bin/openscad")
CACHE_DIR = os.environ.get("OPENSCAD_CACHE_DIR", "/cache")
TIMEOUT_S = int(os.environ.get("OPENSCAD_TIMEOUT", "60"))
# Address-space cap. Manifold on a big grid is comfortably under this; a runaway allocation hits it
# and dies with a clean MemoryError-ish exit instead of taking the container's RAM with it.
MEMORY_LIMIT_BYTES = int(os.environ.get("OPENSCAD_MEMORY_MB", "2048")) * 1024 * 1024
SET_NAME = "s"


class RenderError(Exception):
    """A bad .scad or bad params — a CLIENT condition. The app turns this into 422, never 500."""


@dataclass
class Result:
    bytes: bytes
    cached: bool


def openscad_version():
    try:
        out = subprocess.run([OPENSCAD_BIN, "--version"], capture_output=True, text=True, timeout=15)
        return (out.stdout + out.stderr).strip().splitlines()[0]
    except Exception:
        return "unknown"


def cache_key(scad, params, fmt, version):
    """sha256 over EVERY input that can change the bytes (spec §5.1). Version is included on
    purpose: a bump can legitimately change output geometry, and a stale cache would otherwise serve
    the old mesh forever. sort_keys makes two identical renders hash the same regardless of the
    order the form submitted the fields in."""
    blob = json.dumps(
        {"scad": scad, "params": params, "fmt": fmt, "version": version},
        sort_keys=True, separators=(",", ":"),
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def param_set_json(params, vector_names=frozenset()):
    """Build OpenSCAD's own parameterSets file. Chosen over -D deliberately: -D puts user text
    straight into an argv the shell-free exec still has to type-guess, while this is the
    Customizer's native format and needs no quoting. Note EVERY value is a STRING here — that is
    the file format, not a shortcut."""
    values = {}
    for k, v in (params or {}).items():
        if isinstance(v, bool):
            values[k] = "true" if v else "false"
        elif isinstance(v, (list, tuple)):
            values[k] = "[" + ",".join(str(x) for x in v) + "]"
        elif k in vector_names and isinstance(v, str) and "," in v and not v.startswith("["):
            # schema.py renders a vector as "10,20,30" for a plain text input; put the brackets back.
            values[k] = "[" + v.replace(" ", "") + "]"
        else:
            values[k] = str(v)
    return json.dumps({"parameterSets": {SET_NAME: values}, "fileFormatVersion": "1"})


def _limit():
    # Applied in the child between fork and exec.
    resource.setrlimit(resource.RLIMIT_AS, (MEMORY_LIMIT_BYTES, MEMORY_LIMIT_BYTES))


def render(scad, params, fmt="3mf", cache_dir=None, vector_names=frozenset()):
    cache_dir = cache_dir or CACHE_DIR
    key = cache_key(scad, params, fmt, openscad_version())
    path = os.path.join(cache_dir, f"{key}.{fmt}")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as f:
            return Result(f.read(), cached=True)

    # A FRESH EMPTY temp dir per render (spec §10). It is also the CWD, so a relative `include <>`
    # resolves here rather than anywhere interesting. (This bounds the blast radius; it does not
    # seal it — OpenSCAD's include/import can still walk up. Accepted + documented in the README:
    # nothing sensitive lives in this container.)
    with tempfile.TemporaryDirectory(prefix="oscad-") as work:
        scad_path = os.path.join(work, "model.scad")
        set_path = os.path.join(work, "params.json")
        out_path = os.path.join(work, f"out.{fmt}")
        with open(scad_path, "w", encoding="utf-8") as f:
            f.write(scad)
        with open(set_path, "w", encoding="utf-8") as f:
            f.write(param_set_json(params, vector_names))

        cmd = [OPENSCAD_BIN, "--backend=manifold", "-p", set_path, "-P", SET_NAME,
               "-o", out_path, scad_path]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, cwd=work,
                                  timeout=TIMEOUT_S, preexec_fn=_limit)
        except subprocess.TimeoutExpired:
            raise RenderError(f"render exceeded {TIMEOUT_S}s")

        if proc.returncode != 0:
            raise RenderError(_message(proc))
        # THE 3MF TRAP: a build without lib3mf logs a warning, writes nothing, and EXITS 0. So a
        # zero return code is not evidence of output. Check the bytes.
        if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            raise RenderError(_message(proc) or "render produced no output")

        with open(out_path, "rb") as f:
            data = f.read()

    os.makedirs(cache_dir, exist_ok=True)
    # Write-then-rename: two concurrent identical renders must never let a reader see a half file.
    # PID alone is not a unique writer: gunicorn runs sync workers today (-w 2, one render per
    # process), but adding --threads would put two threads of ONE process on the same tmp path,
    # interleaving their writes into a file that then gets renamed over the cache entry. uuid4
    # costs nothing and makes the name unique per WRITE rather than per process.
    tmp = path + f".{os.getpid()}.{uuid.uuid4().hex}.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return Result(data, cached=False)


def _message(proc):
    """OpenSCAD's useful diagnostics go to stderr, newest last. Surface the ERROR/WARNING lines the
    user can act on rather than the geometry-cache statistics."""
    lines = [l.strip() for l in (proc.stderr or "").splitlines() if l.strip()]
    useful = [l for l in lines if l.startswith(("ERROR", "WARNING", "Parser error"))]
    return " / ".join((useful or lines)[-3:])[:500]


def params_for(scad):
    """--export-format=param on arbitrary source -> the raw Customizer dump (schema.py normalizes)."""
    with tempfile.TemporaryDirectory(prefix="oscad-p-") as work:
        scad_path = os.path.join(work, "model.scad")
        out_path = os.path.join(work, "p.json")
        with open(scad_path, "w", encoding="utf-8") as f:
            f.write(scad)
        try:
            proc = subprocess.run([OPENSCAD_BIN, "--export-format=param", "-o", out_path, scad_path],
                                  capture_output=True, text=True, cwd=work, timeout=30,
                                  preexec_fn=_limit)
        except subprocess.TimeoutExpired:
            raise RenderError("parameter extraction timed out")
        if proc.returncode != 0 or not os.path.exists(out_path):
            raise RenderError(_message(proc) or "could not read parameters")
        with open(out_path, encoding="utf-8") as f:
            return json.load(f)
