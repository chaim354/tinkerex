# boxes-sidecar — GPL-3.0 image (imports boxes; see LICENSE). Internal-only; Rails calls it over
# HTTP and never links it. Build/push this separately from the Rails app image.
FROM python:3.12-slim

WORKDIR /app

# Build deps: git (pip installs boxes from a git ref) + curl (fetch the sample thumbnails below).
# Both are build-only and purged after. SVG generation is pure-Python (boxes' svgwrite surface) — no
# cairo/pango needed. pstoedit (PS/DXF/gcode) is deliberately NOT installed; this API only serves SVG.
RUN apt-get update -qq && apt-get install -y --no-install-recommends git curl && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# boxes.py's own gallery sample photos (THUMBNAILS only — ~2 MB / 231 files, not the full-size
# photos) for the generator tiles. Bundled INTO this GPL image (never the permissive Rails app; §9)
# so the app serves them from our own infra with no external hotlink. Pinned to the SAME commit
# requirements.txt installs, so a photo matches the deployed generator version.
ARG BOXES_REF=836f5f72bedb33ac4262ed925545eacb31e926a8
RUN mkdir -p /app/samples && \
    curl -sL "https://github.com/florianfesti/boxes/archive/${BOXES_REF}.tar.gz" | \
      tar xzf - -C /app/samples --strip-components=3 --wildcards '*/static/samples/*-thumb.jpg' && \
    apt-get purge -y git curl && apt-get autoremove -y

COPY app.py ./

# The GPL-3.0 licence text travels INSIDE the image: we build this and push it to a registry, which
# is redistribution. sidecar/openscad does the same for its GPL-2.0 text. Guarded by
# test/deploy_hygiene_test.rb, which can see this file — the Rails process never loads it.
COPY LICENSE README.md ./

EXPOSE 8000
# 2 workers is plenty for one user; a generate call is CPU-bound and short. Bind on all interfaces
# (the internal Kamal network); never published to the host/internet.
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--timeout", "60", "app:app"]
