# boxes-sidecar — GPL-3.0 image (imports boxes; see LICENSE). Internal-only; Rails calls it over
# HTTP and never links it. Build/push this separately from the Rails app image.
FROM python:3.12-slim

WORKDIR /app

# git: pip installs boxes from a git ref (see requirements.txt). Build-only, removed after.
# SVG generation is pure-Python (boxes' svgwrite surface) — no cairo/pango needed. pstoedit (for
# PS/DXF/gcode) is deliberately NOT installed; this API only exposes SVG.
RUN apt-get update -qq && apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt && apt-get purge -y git && apt-get autoremove -y

COPY app.py ./

EXPOSE 8000
# 2 workers is plenty for one user; a generate call is CPU-bound and short. Bind on all interfaces
# (the internal Kamal network); never published to the host/internet.
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--timeout", "60", "app:app"]
