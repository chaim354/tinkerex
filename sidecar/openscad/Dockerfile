# openscad-sidecar — GPL-2.0 image (ships OpenSCAD; see LICENSE / README.md). Internal-only; the
# permissive Rails app calls it over HTTP on the kamal network and never links it. Built + pushed
# SEPARATELY from the Rails app image (bin/build-openscad-sidecar).
FROM python:3.12-slim

# THE PIN. There is deliberately no "latest" here, for two reasons: openscad.org publishes no
# `-latest-` alias at all (the nightly pointer lives in snapshots/.snapshots.js), and an unpinned
# geometry engine would silently change users' output between rebuilds. Bump both lines together;
# .sha256 sits beside every file on the server.
ARG OPENSCAD_VERSION=2026.07.26
ARG OPENSCAD_SHA256=570a39a199b443c2072312db458a405e18efe51d4c83756e76048ea1069d946c

# Runtime libs. The AppImage bundles 113 of its own (Qt6, lib3mf, boost, cairo…) under usr/lib, so
# this list is only what linuxdeploy's excludelist leaves to the host. It was derived by running
# `ldd` on the extracted binary and installing exactly what came back "not found" — libgpg-error0
# was the single gap, and it is easy to miss because python:3.12-slim is more minimal than the
# excludelist assumes. libasound2 was renamed libasound2t64 in the trixie time64 transition, hence
# the fallback: a hardcoded name breaks on one suite or the other.
#
# libcom-err2 IS LISTED HERE ON PURPOSE AND MUST NOT BE DROPPED AS REDUNDANT. It arrives anyway as a
# transitive dependency of curl, so an `ldd` run before the extraction step reports nothing missing —
# but the extraction RUN ends in `apt-get purge curl && apt-get autoremove`, which sweeps every
# curl dependency that nothing explicitly asked for, libcom-err2 among them. Naming it here marks it
# manually-installed, so autoremove leaves it. Without this line the binary dies with
# `libcom_err.so.2: cannot open shared object file` at the FIRST capability assertion — observed,
# and the assertion is what caught it. This is the same shape of trap as libgpg-error0: derive the
# list against the state the image actually SHIPS in, not the state it passes through.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      curl ca-certificates squashfs-tools \
      libgl1 libglx-mesa0 libegl1 libglvnd0 libopengl0 libglapi-mesa libgbm1 libdrm2 \
      libx11-6 libx11-xcb1 libxcb1 libxcb-dri2-0 libxcb-dri3-0 libxcb-cursor0 \
      libwayland-client0 fontconfig libfontconfig1 libfreetype6 libharfbuzz0b \
      libfribidi0 libexpat1 libuuid1 zlib1g libice6 libsm6 libusb-1.0-0 libgmp10 \
      libstdc++6 libgcc-s1 libgpg-error0 libcom-err2 \
    && (apt-get install -y --no-install-recommends libasound2t64 \
        || apt-get install -y --no-install-recommends libasound2) \
    && rm -rf /var/lib/apt/lists/*

# Fetch + verify + extract. NOTE THE EXTRACTION METHOD: `./x.AppImage --appimage-extract` is the
# documented way and it DOES NOT WORK HERE — the AppImage runtime is a static ELF and Docker
# Desktop's amd64 emulation rejects it with "Exec format error" (exit 126). Every image in this repo
# is cross-built on an arm64 Mac (CLAUDE.md §13), so the build must never EXEC the downloaded
# binary. A type-2 AppImage is just an ELF with a squashfs appended at
# e_shoff + e_shentsize*e_shnum, so unsquashfs reads it directly with no execution at all.
WORKDIR /opt
RUN curl -fsSL -o os.AppImage \
      "https://files.openscad.org/snapshots/OpenSCAD-${OPENSCAD_VERSION}-x86_64.AppImage" && \
    echo "${OPENSCAD_SHA256}  os.AppImage" | sha256sum -c - && \
    OFFSET=$(python3 -c "\
import struct;\
f=open('os.AppImage','rb');\
f.seek(0x28); shoff=struct.unpack('<Q', f.read(8))[0];\
f.seek(0x3a); ent,num=struct.unpack('<HH', f.read(4));\
print(shoff+ent*num)") && \
    unsquashfs -q -o "$OFFSET" -d /opt/openscad os.AppImage && \
    rm os.AppImage && \
    apt-get purge -y curl squashfs-tools && apt-get autoremove -y

# The bundled Qt6/lib3mf/boost libraries live here; AppRun would normally set this. We invoke the
# binary directly (AppRun also exports PYTHONHOME into the AppDir's own Python 3.10, which would
# fight this image's 3.12), so the sidecar sets it explicitly instead.
#
# BUT IT IS SET IN A ONE-LINE WRAPPER, **NOT** AS A GLOBAL `ENV LD_LIBRARY_PATH`, AND THAT IS THE
# WHOLE POINT OF THIS BLOCK. A global ENV applies to EVERY process in the image, and the AppImage
# ships its own older libcrypto.so.3 under usr/lib. LD_LIBRARY_PATH outranks the system paths, so
# this image's Python resolved _ssl against the AppImage's copy and died with
# `libcrypto.so.3: version OPENSSL_3.3.0 not found` — observed: `pip install flask` could not reach
# pypi at all ("the ssl module is not available"), and the same breakage would hit gunicorn, Flask
# and every outbound HTTPS call at RUNTIME, from an image whose six OpenSCAD assertions all passed.
# The AppImage's lib dir belongs to the one process that wants it and to nothing else. Callers exec
# $OPENSCAD_BIN and inherit nothing special, so render.py needs no knowledge of any of this.
RUN printf '%s\n' '#!/bin/sh' \
      'export LD_LIBRARY_PATH=/opt/openscad/usr/lib' \
      'exec /opt/openscad/usr/bin/openscad "$@"' > /usr/local/bin/openscad && \
    chmod +x /usr/local/bin/openscad
# Qt is linked in and resolves its plugins at startup even for a pure-CPU export. Cheap insurance
# against a headless container: no X server is needed for 3MF (only PNG preview builds a GL context).
ENV QT_QPA_PLATFORM=offscreen
ENV OPENSCAD_BIN=/usr/local/bin/openscad

# Guards the trap described above, at build time, where it is cheap. Without the wrapper this line
# is what fails; with a global LD_LIBRARY_PATH it fails no matter how healthy OpenSCAD looks.
RUN python3 -c "import ssl, urllib.request" && \
    echo "assert: the image's own Python still has a working ssl module"

# THE BUILD-TIME CAPABILITY ASSERTION (spec §4). Manifold and 3MF are compile-time optional and a
# build missing either is invisible at runtime — 3MF without lib3mf writes nothing and exits 0.
# `set -e` in the script means any failure fails this RUN and therefore the whole build.
COPY probe.scad /probe.scad
COPY assert-capabilities.sh /assert-capabilities.sh
RUN chmod +x /assert-capabilities.sh && /assert-capabilities.sh

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY catalog/ ./catalog/
COPY *.py ./

# THE LICENCE AND THE SOURCE OFFER MUST BE *IN* THE IMAGE, not just in the repo. This image ships
# GPL-2.0 binaries (OpenSCAD), and someone who runs `docker pull` never sees sidecar/openscad/ —
# so without this line they receive GPL software with no licence text and no written offer beside
# it. CLAUDE.md §9 is about what we SHIP, and the image is what ships.
COPY LICENSE README.md ./
COPY catalog/NOTICE ./catalog/NOTICE

# The render cache (spec §5.1) lives on a mounted volume; create it so an unmounted run still works.
# Owned by the run-as user below, because a mounted volume inherits the image's ownership for its
# initial contents and gunicorn must be able to write cache entries.
RUN mkdir -p /cache && \
    useradd --create-home --uid 10001 openscad && \
    chown -R openscad:openscad /cache /app
ENV OPENSCAD_CACHE_DIR=/cache

# NON-ROOT (spec §10). This container execs user-supplied .scad, which is arbitrary code execution
# BY DESIGN — that is what a generator is. The bound is resource-shaped (timeout + RLIMIT_AS) and
# blast-radius-shaped, and running as root would have thrown away the second half for nothing:
# nothing here needs privilege after the build steps are done.
USER openscad

EXPOSE 8000
# --timeout 120 must stay ABOVE the 60 s per-render timeout in render.py. Gunicorn's timeout kills
# the WORKER, so setting it at or below the render timeout means a slow render is reported as a
# worker crash instead of the clean 422 the app knows how to display.
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--timeout", "120", "app:app"]
