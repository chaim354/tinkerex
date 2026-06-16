# Building the desktop app (cross-OS, downloadable installers)

The `.github/workflows/build-app.yml` workflow builds the **Maker** Tauri desktop app
(`client/maker-app`) on macOS, Windows, and Linux and uploads runnable installers as
workflow artifacts. Dispatch it on demand, download the artifact for your OS, and run it
on any machine of that OS.

> **What this builds.** The file-sync app (`client/maker-app`). It bundles the native
> sync daemon + the per-OS mount backend (macOS = WebDAV, Linux = FUSE, Windows = CfAPI),
> all over the same `Provider`. The workflow only *bundles* the app — it does not mount a
> filesystem in CI, so the interactive-session caveats that gate the live-mount jobs
> (`rust-client.yml` / `nightly.yml`) don't apply here. It runs on GitHub-hosted runners.

---

## 1. Dispatch a build

From the GitHub UI: **Actions → Build app → Run workflow**, pick a branch, optionally pick
an OS (`all` / `macos` / `windows` / `linux`).

Or from the CLI (`gh`):

```sh
# All three OSes off the current branch:
gh workflow run build-app.yml --ref main

# One OS only:
gh workflow run build-app.yml --ref main -f os=macos

# A different Tauri crate (e.g. a second UI app), if one exists in the repo:
gh workflow run build-app.yml --ref my-branch -f crate=client/maker-library-ui-tauri
```

It also runs automatically on a version **tag** matching `app-v*` (e.g. `app-v0.1.0`),
which additionally attaches the installers to a **draft GitHub Release** (see §5).

---

## 2. Download the artifact

When the run finishes, grab the per-OS artifact:

```sh
gh run list --workflow build-app.yml          # find the run id
gh run download <run-id> -n maker-app-macos   # or maker-app-windows / maker-app-linux
```

Or from the UI: open the run → **Artifacts** at the bottom → download the zip.

Each artifact contains the installers built for that OS:

| OS | Artifact | Contents |
|----|----------|----------|
| macOS | `maker-app-macos` | `*.dmg` (disk-image installer) + `*.app.zip` (the raw app, drag to /Applications) |
| Windows | `maker-app-windows` | `*.msi` (WiX) + `*-setup.exe` (NSIS installer) |
| Linux | `maker-app-linux` | `*.deb` (Debian/Ubuntu) + `*.AppImage` (portable, most distros) |

GitHub wraps every artifact in its own outer `.zip` on download — unzip that first to get
the installer files.

---

## 3. Install / run per OS

### macOS — `.dmg` or `.app`
1. Open the `.dmg`, drag **maker-app** to Applications. (Or unzip `maker-app.app.zip` and
   move the `.app` yourself.)
2. First launch: because the app is **unsigned / un-notarized** (see §6), Gatekeeper will
   refuse it with *"maker-app cannot be opened because the developer cannot be verified."*
   Bypass it once: **right-click the app → Open → Open**, or
   `System Settings → Privacy & Security → Open Anyway`. From the terminal you can also
   strip the quarantine attribute:
   ```sh
   xattr -dr com.apple.quarantine /Applications/maker-app.app
   ```
3. On Apple-Silicon CI (`macos-latest` is arm64) the `.dmg` is `aarch64`. For an Intel Mac
   you'd build an `x86_64` (or universal) target — see §7.

### Windows — `.msi` or `.exe`
1. Double-click the `.msi` or the `*-setup.exe` (NSIS).
2. First launch: **SmartScreen** ("Windows protected your PC") will warn because the app is
   **not code-signed** (see §6). Click **More info → Run anyway**.
3. The default Windows mount backend is **CfAPI** (driverless — no WinFsp install, no
   `winfsp-x64.dll` needed). If you build the legacy WinFsp backend instead (the
   `winfsp-backend` cargo feature), the target machine additionally needs WinFsp installed
   / the DLL on PATH.

### Linux — `.deb` or `.AppImage`
- **`.deb`** (Debian/Ubuntu): `sudo apt install ./maker-app_*.deb` — apt pulls the runtime
  libs the package declares (webkit2gtk-4.1, libfuse, …). Then launch **maker-app** from
  your menu or run the binary.
- **`.AppImage`** (most distros, no install): `chmod +x maker-app_*.AppImage && ./maker-app_*.AppImage`.
- **FUSE mount prerequisites** (only needed to actually *mount* a synced drive, not to launch):
  libfuse present, and `user_allow_other` in `/etc/fuse.conf` + access to `/dev/fuse`
  (see `client/maker-app/SETUP.md`).

Once running, point the app at a sync server and mount — see `client/maker-app/SETUP.md`
for the run-and-mount walkthrough.

---

## 4. What the workflow installs per OS (build deps)

Each OS compiles only its own mount backend (target-gated in `sync-engine`), so the build
deps differ:

- **Linux** — Tauri's GTK/WebKit stack (`libwebkit2gtk-4.1-dev`, `libgtk-3-dev`,
  `libayatana-appindicator3-dev`, `librsvg2-dev`, `libxdo-dev`) + `libfuse-dev`/`pkg-config`
  (FUSE is `fuser`, `cfg(target_os = "linux")`). libfuse ships the standard `fuse.pc`, so no
  pkg-config alias dance.
- **Windows** — WinFsp + LLVM/libclang. The default backend is CfAPI (driverless), but
  `sync-engine` still compiles `fs-winfsp` transitively, and its `winfsp-sys` runs bindgen
  against the WinFsp SDK headers (needs libclang). `windows-latest` ships LLVM.
- **macOS** — **nothing filesystem-related.** The app mounts via native WebDAV at runtime,
  and `fuser` is `cfg(target_os = "linux")` so it isn't compiled here. No FUSE-T, no
  pkg-config alias. (Verified locally: the `.app` and `.dmg` bundle on macOS with zero FUSE
  setup.) Xcode Command-Line Tools (`codesign`, `hdiutil`) are preinstalled.

---

## 5. Tag builds → draft Release

Pushing a tag `app-v*` builds all three OSes and attaches every installer to a **draft**
GitHub Release (you review and publish it manually):

```sh
git tag app-v0.1.0 && git push origin app-v0.1.0
```

The draft Release is *in addition to* the per-OS workflow artifacts (artifacts expire after
14 days; the Release is permanent once published).

---

## 6. Signing / notarization caveats (important for *distribution*)

The workflow produces **unsigned** artifacts. They are perfectly **runnable** (with the
one-time Gatekeeper/SmartScreen bypass in §3), which is all you need to hand a build to a
teammate or test on another machine. For **public distribution** you need paid certificates:

- **macOS notarization** — requires a paid **Apple Developer Program** membership ($99/yr):
  a *Developer ID Application* certificate to **codesign** the `.app`, then **notarize** it
  with Apple (`notarytool`) and **staple** the ticket. Without it, users hit the
  "developer cannot be verified" Gatekeeper prompt. Tauri reads the signing identity from
  `APPLE_CERTIFICATE` / `APPLE_SIGNING_IDENTITY` / `APPLE_ID` / `APPLE_PASSWORD` /
  `APPLE_TEAM_ID` env vars during `tauri build` — wire those as repo secrets to enable it.
- **Windows code-signing** — requires a paid **code-signing certificate** (OV ~$100–300/yr,
  or an EV cert / Azure Trusted Signing for immediate SmartScreen reputation). Without it,
  users hit the SmartScreen "unknown publisher" warning. Tauri signs via the
  `WINDOWS_CERTIFICATE` / `WINDOWS_CERTIFICATE_PASSWORD` config or a `signCommand` — wire a
  cert secret to enable it.
- **Linux** — no OS-level signing gate. `.deb`/`.AppImage` run as-is. (You *can* GPG-sign a
  `.deb` for an apt repo, but it's not required to install.)

These are deliberately **left out** of the default workflow (no secrets required → the build
works for anyone who forks/clones). Add the secrets above and Tauri picks them up
automatically; nothing else in the workflow changes.

---

## 7. Notes / future extensions

- **Architectures.** `macos-latest` is arm64 (Apple Silicon) and `ubuntu-latest`/
  `windows-latest` are x86_64. For a universal macOS binary or an Intel build, add
  `--target universal-apple-darwin` (and the rustup target) to the macOS leg; for Linux
  arm64, add an `aarch64` runner/target. The matrix in `build-app.yml` is the place to do
  it.
- **A second Tauri app.** The workflow is parameterized by `-f crate=<path>`: point it at
  any crate containing `src-tauri/tauri.conf.json` to build a different UI app (e.g. a
  separate library UI) without editing the workflow. The default is `client/maker-app`.
- **Caching.** cargo registry/git + the crate's `src-tauri/target` are cached per
  OS+lockfile, so re-dispatches after the first are much faster.

---

## CI-verified vs locally checked

- **Locally verified on this macOS box:** the macOS leg end-to-end — `cargo tauri build`
  produces both `maker-app.app` and `maker-app_<v>_aarch64.dmg` with **zero FUSE/pkg-config
  setup** (confirms `fuser` is correctly Linux-gated), and the workflow's artifact-staging
  script (zip the `.app`, glob the `.dmg`) was run against the real bundle output.
- **YAML/static-verified:** the whole workflow passes `actionlint` clean. `tauri.conf.json`
  is valid JSON with `bundle.active = true` and an identifier/productName set.
- **CI-only (not runnable on this box):** the Windows and Linux legs. They follow the same
  documented build deps as the repo's existing `rust-client.yml` Windows/Linux jobs (WinFsp
  + LLVM; libfuse + webkit2gtk), so they're expected to bundle, but the first dispatch on
  `windows-latest` / `ubuntu-latest` is the real confirmation.
