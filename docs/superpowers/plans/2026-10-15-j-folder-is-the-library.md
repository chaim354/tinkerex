# J — The compose file's folder is the library: implementation plan

> **For agentic workers:** execute with `.claude/commands/execute-plan.md` (this repo's default: one
> task = one unit owned end-to-end by one implementer, independent tasks in parallel, no
> spec-compliance stage, one capped quality review per task). Steps use checkbox (`- [ ]`) syntax.
> Spec: `docs/superpowers/specs/2026-10-15-j-folder-is-the-library-design.md`.

**Goal:** a stranger with a folder of files drops `docker-compose.yml` into it, runs
`docker compose up -d` there, and the app indexes that folder and runs as its owner, with the
first screen naming the folder.

**Architecture:** three small changes. The compose file mounts `.` instead of `./library` (the
build overlay puts `./library` back for clones) and passes `LIBRARY_HOST_PATH` through display-only;
one view helper turns that variable's three states into the folder sentence the shared partial
renders; the entrypoint infers `PUID`/`PGID` from the mounted folder's owner when `PUID` is unset.

**Tech stack:** Rails 8.1.3.1, bash entrypoint, Docker Compose 2.24+, Minitest.

---

## Facts the tasks rely on (verified 2026-10-15 against `main` fd498356)

- Compose resolves a relative bind source against the compose file's directory, and merges a
  service's `volumes` by container path across `-f` files: a base `.:/library` plus an overlay
  `./library:/library` resolves to two mounts, the storage volume and the overlay's bind
  (measured with `docker compose config`, 2026-10-15). No `!override` tag is needed.
- `docker-compose.yml:23` mounts `${LIBRARY_HOST_PATH:-./library}:/library`; `web`'s
  `environment` has `PUID`, `PGID`, `RAILS_MAX_THREADS` and the three Tools URLs.
  `docker-compose.build.yml` sets only `image:` and `build:` per service.
- `test/compose_hygiene_test.rb` pins `web["volumes"]` as exactly
  `["tinkerex_storage:/rails/storage", "${LIBRARY_HOST_PATH:-./library}:/library"]`.
- `bin/docker-entrypoint` reads `PUID="${PUID:-1000}"`, `PGID="${PGID:-1000}"` inside the root
  branch; the library path is `library="${LIBRARY_PATH:-/library}"`; the only owner check is the
  portable `find "$1" -maxdepth 0 -user "$2" -group "$3"`. `stat -c` is GNU (the image, Linux
  runners); macOS has BSD `stat -f`. `test/docker_entrypoint_test.rb`'s `run_entrypoint` passes
  `LIBRARY_PATH` = a temp `library` dir owned by the test process and `PUID`/`PGID` = nil.
- `app/views/shared/_where_files_come_from.html.erb:33-36` is the share sentence
  ("**The library folder on the server** is your library. Anything put there, …");
  `test/integration/web/where_files_come_from_test.rb:61,110` match
  `/library folder on the server.*within 15 minutes.*Rescan library/` with no `LIBRARY_HOST_PATH`
  in the test environment. Helpers under `app/helpers/` are included in every view.
- `test/install_docs_test.rb` scans `app/` for `ENV["…"]` reads: a new read of
  `LIBRARY_HOST_PATH` in a helper is satisfied by the existing row in INSTALL.md's table.
- `lib/library_backend_check.rb:185-189` says "(default: ./library beside the compose file)".
- `unraid/tinkerex.xml:37-38` are the `PUID` (Default 99, Required) and `PGID` (100) fields.
- Docs anchors: README.md:28-36 (quick start and first run); docs/INSTALL.md:20-22 (§1 "A folder
  for your files"), :35 ("Make a folder, put …"), :59 (first "Where your files come from"
  bullet), :92 (`LIBRARY_HOST_PATH` bullet), :99 (`PUID` bullet), :314-316 (the Compose-only
  heading and the two rows); .env.example:11-18.

## File map

| task | creates | modifies | test |
|---|---|---|---|
| 1 | — | `docker-compose.yml`, `docker-compose.build.yml` | `test/compose_hygiene_test.rb` |
| 2 | — | `bin/docker-entrypoint` | `test/docker_entrypoint_test.rb` |
| 3 | `app/helpers/library_folder_helper.rb` | `app/views/shared/_where_files_come_from.html.erb` | `test/integration/web/where_files_come_from_test.rb` |
| 4 | — | `README.md`, `docs/INSTALL.md`, `.env.example`, `lib/library_backend_check.rb`, `docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md` | `test/install_docs_test.rb`, `test/lib/library_backend_check_test.rb` (existing) |
| 5 | — | `unraid/tinkerex.xml` | `xmllint` |
| 6 | — | — | the real runs (orchestrator) |

Tasks 1–5 touch disjoint paths and run in parallel.

---

### Task 1: the compose file's folder is the library

**Files:**
- Modify: `docker-compose.yml`
- Modify: `docker-compose.build.yml`
- Test: `test/compose_hygiene_test.rb`

- [ ] **Step 1: Change the failing assertions**

In `test/compose_hygiene_test.rb`, in the test "the app needs no .env, carries the Tools URLs and
the thread count, and keeps its two mounts", replace the `volumes` assertion with:

```ruby
    assert_equal [ "tinkerex_storage:/rails/storage", "${LIBRARY_HOST_PATH:-.}:/library" ], web["volumes"],
                 "the compose file's own folder is the library (J): '.' resolves against the file, not the shell's cwd"
    assert_equal "${LIBRARY_HOST_PATH:-}", env["LIBRARY_HOST_PATH"],
                 "passed through DISPLAY-ONLY: empty when unset, so the app can say 'the folder your docker-compose.yml is in'"
```

and replace the two `PUID`/`PGID` assertions in that same test with:

```ruby
    assert_equal "${PUID:-}", env["PUID"], "empty when unset, so the entrypoint infers the folder's owner (J)"
    assert_equal "${PGID:-}", env["PGID"]
```

and in the test "the build overlay restores a build for every service under a :local name" add,
after the `each` block:

```ruby
    assert_equal [ "./library:/library" ], services.dig("web", "volumes"),
                 "in a clone '.' is the repository; the overlay puts the mount back to ./library " \
                 "(compose merges volumes by container path, so the storage volume survives)"
```

- [ ] **Step 2: Run, expect 2 failures**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/compose_hygiene_test.rb`
Expected: the two edited tests fail.

- [ ] **Step 3: Edit `docker-compose.yml`**

(a) The header comment's second paragraph currently begins `# Overrides go in an optional .env
beside this file: LIBRARY_HOST_PATH to use an existing folder,`. Replace the whole header comment
(every line before `services:`) with:

```yaml
# Tinkerex with the Tools gallery: four containers, and THE FOLDER THIS FILE IS IN is the library.
# Put the file in the folder that holds your files, or in an empty one, and in that folder:
#
#   docker compose up -d                           pull and start; then http://localhost:8080
#   docker compose pull && docker compose up -d    update
#
# Whatever folder the file is in becomes the library, with a .trash/ inside it, so not Downloads.
# Overrides go in an optional .env beside this file: LIBRARY_HOST_PATH to keep the file here and the
# library elsewhere, PUID/PGID to run as someone other than the folder's owner, TINKEREX_PORT, and
# the accounts/mail knobs (.env.example lists them; docs/INSTALL.md explains them).
# docker-compose.build.yml rebuilds all four images from a clone instead of pulling them;
# docker-compose.chunk_remote.yml adds the sync server (INSTALL.md section 5).
```

(b) In `web`'s `environment`, replace the `PUID`/`PGID` comment and lines with:

```yaml
      # The user the app runs as inside the container. Unset, the entrypoint uses the library
      # folder's owner (so a folder that is yours, or an Unraid share, needs nothing); set them to
      # run as someone else. Docker Desktop (Mac, Windows) needs nothing either way.
      PUID: ${PUID:-}
      PGID: ${PGID:-}
      # DISPLAY-ONLY: the app's one reader (LibraryFolderHelper) turns this into "the folder your
      # docker-compose.yml is in" when empty, or the path as typed. Never a path the app opens.
      LIBRARY_HOST_PATH: ${LIBRARY_HOST_PATH:-}
```

(c) In `web`'s `volumes`, `- ${LIBRARY_HOST_PATH:-./library}:/library` becomes
`- ${LIBRARY_HOST_PATH:-.}:/library`.

- [ ] **Step 4: Edit `docker-compose.build.yml`**

Under `web`, after `build: .`, add:

```yaml
    # In a clone "." is the repository: nobody wants it indexed with a .trash/ inside, so the mount
    # goes back to ./library here (gitignored). Compose merges volumes by container path, which is
    # why this one line replaces the base file's /library mount and keeps the storage volume.
    volumes:
      - ./library:/library
```

- [ ] **Step 5: Prove the merge with Compose itself, then run the test**

```sh
docker compose -f docker-compose.yml config | grep -A12 '^    volumes:' | grep -E 'source:|target:'
docker compose -f docker-compose.yml -f docker-compose.build.yml config | grep -A12 '^    volumes:' | grep -E 'source:|target:'
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/compose_hygiene_test.rb
```

Expected: the base shows two mounts, the bind source being the repository root (the compose file's
directory) with target `/library`; the merged output still shows exactly two mounts, the bind
source now `<repo>/library`. Test: 4 runs, 0 failures. Paste both `config` extracts in the report.

- [ ] **Step 6: Mutation-check, then restore**

1. Change the base mount back to `./library` → the volumes assertion must fail. Restore.
2. Delete the overlay's `volumes:` block → the overlay assertion must fail. Restore.
3. Delete the `LIBRARY_HOST_PATH:` environment line → its assertion must fail. Restore.

- [ ] **Step 7: Commit**

```sh
git add docker-compose.yml docker-compose.build.yml test/compose_hygiene_test.rb
git commit -F - <<'MSG'
The folder the compose file is in is the library; the build overlay keeps ./library for clones

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 2: the entrypoint runs as the folder's owner when PUID is unset

**Files:**
- Modify: `bin/docker-entrypoint`
- Test: `test/docker_entrypoint_test.rb`

- [ ] **Step 1: Write the failing tests**

Add after the test "directories already owned by PUID:PGID are not chowned, …":

```ruby
  test "PUID unset: the library folder's owner becomes the app user, and the log says so" do
    out, status, calls = run_entrypoint("echo", "hi")
    assert status.success?, out
    assert_includes calls, "setpriv --reuid=#{Process.uid} --regid=#{Process.gid} --clear-groups #{@entrypoint} echo hi",
                    "the temp library is owned by this process, so that is the user to run as: #{calls}"
    assert_empty calls.grep(/library/), "inferring the owner never chowns the folder: #{calls}"
    assert_match(/PUID=#{Process.uid} PGID=#{Process.gid} \(inferred from .*library's owner\)/, out)

    # The compose file passes PUID="" when nothing is set; empty must mean unset, not uid "".
    out, status, calls = run_entrypoint("echo", "hi", env: { "PUID" => "", "PGID" => "" })
    assert status.success?, out
    assert_equal 1, calls.grep(/\Asetpriv --reuid=#{Process.uid} --regid=#{Process.gid} /).size, calls.inspect
  end

  test "PUID unset and no library folder: 1000:1000, the default, and the log says so" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "LIBRARY_PATH" => File.join(@root, "absent") })
    assert status.success?, out
    assert_equal 1, calls.grep(/\Asetpriv --reuid=1000 --regid=1000 /).size, calls.inspect
    assert_match(/PUID=1000 PGID=1000 \(default\)/, out)
  end

  test "PUID set and PGID unset: no inference, PUID wins and PGID is 1000" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "PUID" => "99" })
    assert status.success?, out
    assert_equal 1, calls.grep(/\Asetpriv --reuid=99 --regid=1000 /).size, calls.inspect
    assert_match(/PUID=99 PGID=1000 \(set\)/, out)
  end
```

`Open3.capture2e` already merges stderr into `out`, which is where the log line goes.

- [ ] **Step 2: Run, expect 3 failures**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/docker_entrypoint_test.rb`
Expected: the three new tests fail (the first on the setpriv ids, the other two on the log line).

- [ ] **Step 3: Edit the entrypoint**

Replace, inside the `if [ "$(id -u)" = "0" ]; then` branch, the two lines

```bash
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
```

with:

```bash
  # RUN AS THE FOLDER'S OWNER WHEN NOTHING SAYS OTHERWISE (J, 2026-10-15). A folder that is yours,
  # an Unraid share (nobody:users), a NAS export owned by some other uid: its owner is the only
  # user that can write there, so with PUID unset that owner is the app's user. A root-owned folder
  # (Docker Desktop's bind mounts read that way; a fresh root-made directory too) keeps the 1000
  # default and the share guard decides. Explicit PUID/PGID win, each on its own; PUID set with
  # PGID unset keeps PGID at 1000, so an operator who pins one is not surprised by the other.
  # `stat -c` is GNU (the image); the `stat -f` arm is BSD, for the test suite on a Mac.
  library="${LIBRARY_PATH:-/library}"
  puid_source="set"
  if [ -z "${PUID:-}" ]; then
    owner=""
    [ -d "$library" ] && owner=$(stat -c '%u:%g' "$library" 2>/dev/null || stat -f '%u:%g' "$library" 2>/dev/null || true)
    case "$owner" in
      ""|0:*) puid_source="default" ;;
      *) PUID="${owner%%:*}"; PGID="${PGID:-${owner##*:}}"; puid_source="inferred from $library's owner" ;;
    esac
  fi
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
  echo "PUID=$PUID PGID=$PGID ($puid_source)" >&2
```

and delete the later line `library="${LIBRARY_PATH:-/library}"` (it is now set above; the
empty-root-owned adoption block keeps using `$library`). Everything else is unchanged: the
integer guard still follows (`case "$PUID$PGID" in *[!0-9]*) …`), then the chowns, the adoption,
`HOME`, and the `PUID != 0` drop.

Order matters: the inference must come BEFORE the integer guard (so an inferred value is
validated like a typed one) and the guard must stay before any chown.

- [ ] **Step 4: Run, expect green**

Same command; 9 runs, 0 failures (the six existing plus three).

- [ ] **Step 5: Build the image and run the inference for real**

```sh
docker build -t tinkerex:j-check . 2>&1 | tail -1
d=$(mktemp -d); mkdir "$d/lib"
docker run --rm -v "$d/lib:/library" tinkerex:j-check sh -c 'id -u; stat -c %u:%g /library' 2>&1 | tail -3
docker run --rm -e PUID=4242 -v "$d/lib:/library" tinkerex:j-check sh -c 'id -u; id -g' 2>&1 | tail -3
docker rmi tinkerex:j-check >/dev/null
```

Expected on Docker Desktop (a bind mount reads as root-owned there): the first run prints the log
line `PUID=1000 PGID=1000 (default)` then `1000` and `0:0`; the second prints `(set)`, `4242`,
`1000`. The non-root-owner case is the Linux run's (Task 6). Paste the output.

- [ ] **Step 6: Mutation-check, then restore**

1. Delete the whole `if [ -z "${PUID:-}" ]; then … fi` block → the "owner becomes the app user" test must fail (setpriv gets 1000:1000). Restore.
2. Change `PGID="${PGID:-1000}"` to `PGID="${PGID:-99}"` → the "PUID set and PGID unset" test must fail on `--regid=1000`. Restore.
3. Change `[ -z "${PUID:-}" ]` to `[ -z "${PUID+x}" ]` (so an EMPTY PUID counts as set) → the empty-string case in the first new test must fail. Restore.
4. The root-owned-folder arm (`""|0:*`) cannot be exercised here, because the temp dir is not root-owned; say so in the report and leave it to the Linux run.

- [ ] **Step 7: Commit**

```sh
git add bin/docker-entrypoint test/docker_entrypoint_test.rb
git commit -F - <<'MSG'
With PUID unset the entrypoint runs as the library folder's owner

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 3: the first screen names the folder

**Files:**
- Create: `app/helpers/library_folder_helper.rb`
- Modify: `app/views/shared/_where_files_come_from.html.erb:33`
- Test: `test/integration/web/where_files_come_from_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/integration/web/where_files_come_from_test.rb`, inside the class, a helper and two
tests (the file already has a `replacing` helper and `text_of`):

```ruby
    def with_library_host_path(value)
      had = ENV.key?("LIBRARY_HOST_PATH")
      was = ENV["LIBRARY_HOST_PATH"]
      value.nil? ? ENV.delete("LIBRARY_HOST_PATH") : ENV["LIBRARY_HOST_PATH"] = value
      yield
    ensure
      had ? ENV["LIBRARY_HOST_PATH"] = was : ENV.delete("LIBRARY_HOST_PATH")
    end

    test "with the compose file's default the panel says the folder the file is in; with a path, the path" do
      with_library_host_path("") do
        get root_path
        assert_response :success
        sources = text_of(".getting-started .file-sources")
        assert_match(/The folder your docker-compose\.yml is in is your library.*within 15 minutes.*Rescan library/, sources)
        assert_no_match(/library folder on the server/, sources)
      end
      with_library_host_path("/Users/me/Workshop") do
        get root_path
        sources = text_of(".getting-started .file-sources")
        assert_match(%r{/Users/me/Workshop is your library.*within 15 minutes}, sources)
        assert_select ".getting-started .file-sources code", text: "/Users/me/Workshop"
      end
      with_library_host_path("<b>x</b>") do
        get root_path
        assert_select ".getting-started .file-sources code", text: "<b>x</b>"
        assert_select ".getting-started .file-sources b", 0, "the value is shown as typed, escaped"
      end
    end

    test "the Library's empty state names the folder the same way" do
      with_library_host_path("") do
        get files_path
        assert_response :success
        assert_match(/The folder your docker-compose\.yml is in is your library/, text_of(".library-main .empty"))
      end
    end
```

- [ ] **Step 2: Run, expect 2 failures**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/web/where_files_come_from_test.rb`
Expected: the two new tests fail on the first `assert_match`; the existing tests pass (no
`LIBRARY_HOST_PATH` in the environment → the absent state → today's sentence).

- [ ] **Step 3: Write the helper**

```ruby
# app/helpers/library_folder_helper.rb
module LibraryFolderHelper
  # THE FOLDER SENTENCE HAS THREE STATES (J, 2026-10-15), told apart by what LIBRARY_HOST_PATH
  # carries inside the container. The compose file passes it through DISPLAY-ONLY -- empty when the
  # person set nothing, so the file's own folder is the library; the path as typed when they set it
  # -- and a Kamal destination never sets it at all. This is the variable's ONE reader in app/: it
  # must never become a path the process opens, because a wrong value here can only mislead a
  # sentence, which is the whole reason it is allowed to come from the person unchecked.
  # `tag.code` escapes the value: it is shown as typed, never interpreted.
  def library_folder_label
    value = ENV["LIBRARY_HOST_PATH"]
    return "The library folder on the server" if value.nil?

    value = value.strip
    return safe_join([ "The folder your ", tag.code("docker-compose.yml"), " is in" ]) if value.empty?

    tag.code(value)
  end
end
```

- [ ] **Step 4: Use it in the partial**

In `app/views/shared/_where_files_come_from.html.erb`, line 33, replace
`<p><strong>The library folder on the server</strong> is your library. Anything put there,` with
`<p><strong><%= library_folder_label %></strong> is your library. Anything put there,`. Add to the
partial's header comment (the ERB comment at the top) one sentence: `The share sentence's subject
comes from LibraryFolderHelper#library_folder_label: three states by LIBRARY_HOST_PATH (absent,
empty, set), display-only.` Keep it a plain sentence with no `%>` inside the comment (§14d).

- [ ] **Step 5: Run, expect green**

Same command, plus the two other suites that render the partial:

```sh
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/web/where_files_come_from_test.rb test/integration/web/home_test.rb test/integration/web/template_hygiene_test.rb
```

Expected: all green.

- [ ] **Step 6: Mutation-check, then restore**

1. In the helper, swap the `nil` and empty arms (return the compose sentence for `nil`) → the
   existing "names every way a file arrives" test must fail (no "library folder on the server").
   Restore.
2. Replace `tag.code(value)` with `value.html_safe` → the `<b>x</b>` assertion must fail. Restore.

- [ ] **Step 7: Commit**

```sh
git add app/helpers/library_folder_helper.rb app/views/shared/_where_files_come_from.html.erb test/integration/web/where_files_come_from_test.rb
git commit -F - <<'MSG'
The Getting started panel names the library folder: the compose file's own, or the path as typed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 4: the guide, README, env example, the guard's message, the handoff

**Files:**
- Modify: `README.md`, `docs/INSTALL.md`, `.env.example`, `lib/library_backend_check.rb`,
  `docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md`
- Test: `test/install_docs_test.rb`, `test/lib/library_backend_check_test.rb` (existing; must pass)

- [ ] **Step 1: README.md**

In **Quick start**, the sentence `Make a folder, download [`docker-compose.yml`](docker-compose.yml)
into it, and in that folder:` becomes `Download [`docker-compose.yml`](docker-compose.yml) into the
folder that holds your files, or into an empty folder, and in that folder:`.

In **First run**, replace from `A `library/` folder has appeared beside the compose file` to the end
of that paragraph with: `That folder is your library: the compose file's own folder, files and all.
To keep the file somewhere else, `LIBRARY_HOST_PATH=/path/to/files` in a `.env` beside it names the
folder instead.`

- [ ] **Step 2: docs/INSTALL.md**

(a) §1, the bullet `- **A folder for your files**, or nothing: the first start makes an empty
`library/` folder beside the compose file, and you can point it at an existing folder afterwards
(section 3).` becomes `- **A folder for your files**, or an empty one: the folder you put the compose
file in is the library.`

(b) §2, line 35: `Make a folder, put [`docker-compose.yml`](../docker-compose.yml) in it (download it
from this repository), and in that folder:` becomes `Put [`docker-compose.yml`](../docker-compose.yml)
(download it from this repository) in the folder that holds your files — or in an empty folder — and
in that folder:`. After that code fence's closing line add a paragraph: `Whatever folder the file is
in becomes the library: it is indexed, uploads land in it, and deleted files move to a `.trash/`
inside it. So not your Downloads folder.`

(c) §2 "Where your files come from", the first bullet's opening `- **The `library/` folder beside the
compose file is your library** — or the folder you name in section 3.` becomes `- **The folder the
compose file is in is your library** — or the folder you name in section 3.`

(d) §3, the `LIBRARY_HOST_PATH` bullet's opening `the folder that holds your files, instead of
`./library`.` becomes `the folder that holds your files, when it is not the compose file's own
folder.`

(e) §3, the `PUID`/`PGID` bullet becomes:

```markdown
- **`PUID` and `PGID`** (Linux) — the user and group the app runs as inside the container. By
  default it runs as **the owner of your folder**, so there is nothing to set when the folder is
  yours or an Unraid share (`99`/`100`). Set them when the folder is owned by root (the default is
  then `1000`; `id -u` and `id -g` print yours) or to run as a different user on purpose. Files the
  app writes into your folder are owned by that user, and the boot checks it can write there.
  Docker Desktop on Mac and Windows presents your folders as writable by any user, so there is
  nothing to set there. The app never changes your folder's ownership — it only probes it — with
  one exception: an empty folder owned by root (the one Docker itself creates on Linux for a
  missing bind-mount source) is made the app user's, so a fresh install works on the first start.
```

(f) §8: the heading row `| **Compose only** (`docker-compose.yml` reads these; the app never sees
them, except `PUID`/`PGID`, which reach the container's entrypoint) | | | |` becomes
`| **Compose only** (`docker-compose.yml` reads these; the app never sees them, except
`LIBRARY_HOST_PATH`, passed through display-only, and `PUID`/`PGID`, which reach the entrypoint) | | | |`.
The `LIBRARY_HOST_PATH` row becomes:

```markdown
| `LIBRARY_HOST_PATH` | no | the compose file's own folder (`.`) | The folder on the host bound to `/library`; a relative path is resolved against the compose file's directory. Also passed into the container display-only, so the Getting started panel can name the folder ("the folder your docker-compose.yml is in", or the path as typed). Section 3. |
```

and the `PUID`, `PGID` row's default cell becomes `the library folder's owner, else `1000``, with
its description starting `The user and group the app runs as inside the container, and so the owner
of every file it writes into your folder (section 3). Unset, the folder's owner when it is not root;`
and the rest unchanged.

- [ ] **Step 3: .env.example**

Lines 10-12 become:

```sh
# The folder that holds your files, when it is not the compose file's own folder (the default).
# Absolute, or relative to the compose file.
# LIBRARY_HOST_PATH=/path/to/files
```

and the `PUID`/`PGID` comment (lines 14-16) becomes:

```sh
# ---- Who the app runs as (Linux; Docker Desktop on Mac and Windows needs nothing) ----
# By default the app runs as the owner of your folder (99 and 100 on an Unraid share). Set these to
# run as someone else, or when the folder is owned by root.
```

- [ ] **Step 4: lib/library_backend_check.rb**

In the "does not exist" message, `(default: ./library beside the compose file)` becomes
`(default: the compose file's own folder)`.

- [ ] **Step 5: the handoff**

In `docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md`, under `### 3.1 The empty
state does not name the folder`, insert as the first line: `**Shipped by J (2026-10-15):** the
shared partial's subject comes from `LibraryFolderHelper`, reading `LIBRARY_HOST_PATH` display-only —
"the folder your docker-compose.yml is in" when the compose file sets it empty, the path as typed
when set, today's sentence when absent.`

- [ ] **Step 6: Run the guards and sweep**

```sh
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/install_docs_test.rb test/docs_hygiene_test.rb test/lib/library_backend_check_test.rb
grep -n -E 'library/|\./library|has appeared' README.md docs/INSTALL.md .env.example
```

Expected: green; every remaining `./library` hit is the build overlay (INSTALL §3's "Building from
source" paragraph and the `TINKEREX_IMAGE`/overlay rows) or the sync overlay, and nothing says a
`library/` folder appears beside the compose file. List the hits in the report.

- [ ] **Step 7: Commit**

```sh
git add README.md docs/INSTALL.md .env.example lib/library_backend_check.rb docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md
git commit -F - <<'MSG'
The guide: put the compose file in your folder; the app runs as that folder's owner

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 5: the Unraid template's uid fields become optional

**Files:**
- Modify: `unraid/tinkerex.xml:37-38`

- [ ] **Step 1: Edit the two fields**

```xml
  <Config Name="PUID" Target="PUID" Default="" Mode="" Description="Leave empty to run as the share's owner (99, nobody, on a stock Unraid share). Set it to run as someone else." Type="Variable" Display="advanced" Required="false" Mask="false"></Config>
  <Config Name="PGID" Target="PGID" Default="" Mode="" Description="Leave empty to run as the share's group (100, users, on a stock Unraid share). Set it with PUID to run as someone else." Type="Variable" Display="advanced" Required="false" Mask="false"></Config>
```

and in the XML comment at the top, `The container runs as PUID:PGID, 99:100 by default here
(Unraid's own nobody:users), so the` becomes `The container runs as the share's owner unless
PUID:PGID say otherwise (nobody:users, 99:100, on a stock share), so the`. In `<Overview>`, `It runs
as PUID:PGID, 99:100 by default (nobody:users), so uploads land on the share owned the way your
other files are.` becomes `It runs as the share's owner, so uploads land on the share owned the way
your other files are.`

- [ ] **Step 2: Check**

```sh
xmllint --noout unraid/tinkerex.xml && echo well-formed
grep -c 'Required="true"' unraid/tinkerex.xml
```

Expected: `well-formed`; the required count drops by two from before the edit.

- [ ] **Step 3: Commit**

```sh
git add unraid/tinkerex.xml
git commit -F - <<'MSG'
The Unraid template runs as the share's owner unless told otherwise

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 6: the real runs (orchestrator, after Tasks 1–5 are merged)

- [ ] **Step 1: Mac, a folder that already holds files.** Build `tinkerex:local` and the three
  Tools images from the clone with the build overlay (`docker compose -f docker-compose.yml -f
  docker-compose.build.yml build`), then in a temp folder containing three sample files and a copy
  of `docker-compose.yml` ONLY, run `TINKEREX_IMAGE=tinkerex:local docker compose up -d` with the
  three Tools images retagged to their ghcr names locally (`docker tag boxes-sidecar:local
  ghcr.io/chaim354/boxes-sidecar:latest` etc., so no pull is attempted). Poll `/up`; sign up; the
  Library must list the three files and the compose file; Recent's panel must say "the folder your
  docker-compose.yml is in"; an upload must land beside the sample files. Tear down with `down -v`,
  untag the three ghcr names.
- [ ] **Step 2: Mac, the clone.** `docker compose -f docker-compose.yml -f docker-compose.build.yml
  up -d web`; confirm with `docker compose … config` and `docker inspect` that `/library` is the
  clone's `library/`, not the repository root. Tear down.
- [ ] **Step 3: Linux host, the owner inference.** A folder owned by uid 1500 with two files, no
  `PUID`: the log line reads `(inferred from /library's owner)`, PID 1 is 1500, the files are
  indexed (`/up` 200 then the Library via the API or a `docker compose exec` through the
  entrypoint of `bin/rails runner 'puts Node.count'`), a write through the entrypoint lands as
  1500 on the host. The same folder with `PUID=1000` set: refused by the probe. Clean up as last
  time (anchored rsync excludes, scp'd script, `</dev/null` on docker commands, `docker system df`).
- [ ] **Step 4: `bin/ci`**, three identical run counts.
