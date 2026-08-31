# Forgejo → Kaneo Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md` is the
> DEFAULT and overrides any generic subagent loop — batch by FILE, run independent tasks in PARALLEL,
> no spec-compliance stage, cap quality reviews to named claims. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Move the canonical work record (186 issues, `tinkerex#6`–`#193`) from the self-hosted
Forgejo to a self-hosted Kaneo, preserving every issue number so the 129 `tinkerex#N` citations in
the tree keep resolving, and repoint `bin/log` at it.

**Architecture:** Deploy Kaneo 2.18.0 as a Portainer stack behind Nginx Proxy Manager. Probe the live
API before writing any code against it. Export Forgejo to a JSON file, import into a single Kaneo
project in strict ascending number order with placeholder tasks burning the gaps, verify by read-back,
then swap `bin/log`'s transport. `bin/log`'s interface, exit codes and spool behaviour do not change.

**Tech Stack:** Ruby stdlib only (`bin/log` loads no gem — §14j), Net::HTTP, Kaneo REST API
(`Authorization: Bearer`), Portainer 2.39.6, Nginx Proxy Manager, 1Password via `bin/secret`.

**Spec:** `docs/superpowers/specs/2026-08-30-forgejo-to-kaneo-design.md`

---

## Ground rules for this plan

**Phases A and B gate everything else.** Nothing in Phase C onward runs until the counter probe in
Task 4 passes. If it fails, stop and re-open the design — the fallback (renumber + rewrite) is still
available at that point and costs nothing extra.

**Probe before you write.** `bin/log`'s own comments record a shipped bug where the label wire format
was asserted rather than observed, and no stub test could have caught it: `StubForgejo` records what
we send and models nothing, so a wire-format test pins a contract that may be invented. §14e's FakeS3
rule guards the code and the fake sharing a misunderstanding *of each other*; it does not guard both
misunderstanding the *server*. Tasks 4 and 5 exist for that reason.

**Tasks 1, 2 and 20 need a human at a browser.** Portainer's stack editor, the Kaneo signup form, the
NPM proxy host and the 1Password entries are UI actions. Those steps say so explicitly.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `ops/kaneo-stack.yml` | create | The Portainer stack definition, committed so the deploy is reviewable and reproducible. Not executed by anything in the repo. |
| `bin/migrate-record` | create, delete in Task 21 | One-time migration tool: `export`, `probe`, `import`, `verify`. Stdlib only, same constraint as `bin/log`. |
| `bin/log` | modify | Transport swaps to Kaneo. Interface, exit codes, spool unchanged. |
| `test/support/stub_kaneo.rb` | create (from `stub_forgejo.rb`) | Localhost stand-in. Mechanics unchanged — it records verbatim and models nothing. |
| `test/support/stub_forgejo.rb` | delete | Renamed. |
| `test/log_cli_test.rb` | modify | 44 tests; most survive with URL/payload edits. |
| `CLAUDE.md` | modify | §11 base URL, §13 cheatsheet, §15 close-out. **Line-neutral edits only** — the file is at its 1,355-line ceiling. |
| `.claude/commands/{deploy,execute-plan,finish-branch}.md` | modify | One mention each. |
| `config/ci.rb`, `test/docs_hygiene_test.rb` | modify | One mention each. |
| 13 files in `app/` and `test/` | modify | "the Forgejo record (CLAUDE.md §11)" → "the record (CLAUDE.md §11)". |

---

# Phase A — Stand up Kaneo

### Task 1: The Portainer stack

**Files:**
- Create: `ops/kaneo-stack.yml`

- [ ] **Step 1: Write the stack file**

Three deliberate departures from upstream's compose, each commented in place so a later editor does
not "restore" them:

```yaml
# The Kaneo stack, deployed through Portainer (portainer.home, 2.39.6) on the Unraid box.
#
# THIS FILE IS NOT EXECUTED BY ANYTHING IN THIS REPO. It is committed so the deploy is reviewable
# and reproducible; Portainer holds the running copy. Edit here, then paste into the stack editor.
#
# THREE DELIBERATE DEPARTURES FROM UPSTREAM'S compose.yml — do not "restore" them:
#
#   1. THE IMAGE IS PINNED. Upstream uses `:latest`. A floating tag on the box holding the
#      canonical record (CLAUDE.md §11) upgrades it without anyone deciding to, and the first
#      anyone would know is a changed API shape under bin/log.
#   2. POSTGRES PUBLISHES NO PORT. Upstream publishes 5432. Nothing off-box needs it, and the
#      kaneo container reaches it on the stack network by service name.
#   3. NO MINIO. Object storage is optional upstream and powers only image uploads inside task
#      descriptions and comments. The record is 1 MB of markdown with no images, so the service is
#      omitted rather than configured — see the spec's §7.
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: kaneo
      POSTGRES_USER: kaneo
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - kaneo_postgres_data:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U kaneo -d kaneo"]
      interval: 10s
      timeout: 5s
      retries: 5

  kaneo:
    image: ghcr.io/usekaneo/kaneo:2.18.0
    ports:
      - "5173:5173"
    environment:
      KANEO_CLIENT_URL: http://kaneo.home
      DATABASE_URL: postgresql://kaneo:${POSTGRES_PASSWORD}@postgres:5432/kaneo
      POSTGRES_DB: kaneo
      POSTGRES_USER: kaneo
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      AUTH_SECRET: ${AUTH_SECRET}
      # BOTH ARE SET IN TASK 2, NOT HERE. The instance admin is whoever signs up FIRST
      # (GET /instance/status reports hasUsers:false until then), so registration must be OPEN for
      # exactly one signup and closed immediately after. Setting them now locks you out of your own
      # instance.
      DISABLE_REGISTRATION: "false"
      DISABLE_GUEST_ACCESS: "false"
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:5173/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

volumes:
  kaneo_postgres_data:
```

- [ ] **Step 2: Generate the two secrets**

Run:

```bash
echo "AUTH_SECRET=$(openssl rand -hex 32)"; echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
```

Expected: two lines, the first 64 hex chars (Kaneo requires ≥32 bytes), the second 48.

**Store both in 1Password now, before pasting them anywhere** — a value that exists only in terminal
scrollback is one `clear` from being unrecoverable, and `AUTH_SECRET` changing invalidates every
session and API key.

- [ ] **Step 3: Deploy the stack (human, browser)**

In Portainer at `http://portainer.home` → Stacks → Add stack → name `kaneo` → paste
`ops/kaneo-stack.yml` → add the two environment variables `POSTGRES_PASSWORD` and `AUTH_SECRET` →
Deploy.

- [ ] **Step 4: Verify both containers are healthy**

Run:

```bash
curl -s -o /dev/null -w "kaneo health: %{http_code}\n" --max-time 10 http://192.168.1.146:5173/api/health
```

Expected: `kaneo health: 200`. If it is `000`, the container is still starting — the healthcheck
allows a 60 s `start_period`; wait and retry. If it stays `000` past two minutes, read the container
log in Portainer before changing anything.

- [ ] **Step 5: Commit**

```bash
git add ops/kaneo-stack.yml
git commit -m "The Kaneo stack: pinned image, no published Postgres port, no MinIO"
```

---

### Task 2: First run, lockdown, proxy, API key

**Files:** none in the repo — this task is browser work plus one verification command.

- [ ] **Step 1: Confirm the instance has no users yet**

Run:

```bash
curl -s --max-time 10 http://192.168.1.146:5173/api/instance/status
```

Expected: JSON containing `"hasUsers":false`. **If it reports `true`, stop** — someone or something
has already claimed the admin account, and continuing would leave you a non-admin on your own
instance. Tear the stack down (keeping the volume) and investigate.

- [ ] **Step 2: Add the NPM proxy host FIRST — before the signup**

**This step moved ahead of the signup once the deploy landed, and the reason is not cosmetic.**
`KANEO_CLIENT_URL` is `http://kaneo.home`, and better-auth issues session cookies and redirects
against that configured origin. Signing up at `http://192.168.1.146:5173` means the browser's origin
and the server's configured origin disagree — which surfaces as a session that will not stick, or a
redirect straight back to the sign-in page. **The first signup claims instance admin and is not
reversible through the UI**, so it is the one action in this plan that must not need a retry. Do it
on the origin the server already believes it is serving.

At `http://192.168.1.7:81` → Hosts → Proxy Hosts → Add: domain `kaneo.home`, scheme `http`, forward
host **`192.168.1.146`**, forward port `5173`, websockets enabled.

**TWO HOSTS, and confusing them costs an afternoon.** NPM is **192.168.1.7**, where the `*.home`
wildcard resolves — every `.home` name answers from there, including `portainer.home`. Docker runs on
**192.168.1.146** ("Tower", the Unraid host). Probing `.7:5173` after a deploy looks exactly like a
stack that failed to start; it is just the wrong box.

- [ ] **Step 3: Verify the proxy before trusting it with the signup**

```bash
curl -s --max-time 10 http://kaneo.home/api/health; echo
curl -s --max-time 10 http://kaneo.home/ | grep -c "Default Site"
```

Expected: a health response, then `0`. NPM's default site is what `kaneo.home` served before this
step, so a `1` means the proxy host did not take.

- [ ] **Step 4: Claim the admin account (human, browser)**

Open **`http://kaneo.home`** — not the IP — and sign up. **The first signup becomes instance admin**;
this is the one moment that matters and it is not reversible through the UI.

- [ ] **Step 5: Verify the account took**

Run:

```bash
curl -s --max-time 10 http://192.168.1.146:5173/api/instance/status
```

Expected: `"hasUsers":true`.

- [ ] **Step 6: Close registration (human, Portainer)**

Edit the `kaneo` stack: set `DISABLE_REGISTRATION: "true"` and `DISABLE_GUEST_ACCESS: "true"`.
Redeploy. Update `ops/kaneo-stack.yml` to match, so the committed file and the running stack agree —
a committed file that has silently diverged from what runs is the "doc row that names a commit is a
claim" problem in §15, one layer down.

- [ ] **Step 7: Verify registration is actually closed**

Run:

```bash
curl -s --max-time 10 http://192.168.1.146:5173/api/config
```

Expected: the JSON reports registration disabled. **Read the actual field rather than assuming the
env var took** — this is the whole point of the step. If registration still reads as enabled, the
redeploy did not pick up the change.

- [ ] **Step 8: Mint the API key (human, browser)**

In Kaneo at `http://kaneo.home` → Settings → Account → Developer Settings → API Keys → Create API
Key, name it `bin/log`. **Copy it immediately; it is not shown again.**

- [ ] **Step 9: Store the key in 1Password**

Create an item in the `tinkerex` vault named `kaneo key` with the key in its `credential` field, so
the reference is `op://tinkerex/kaneo key/credential` — matching the shape `bin/log`'s existing
`TOKEN_REF` uses. `AUTH_SECRET` and `POSTGRES_PASSWORD` from Task 1 go in the same vault.

- [ ] **Step 10: Verify the key works end to end through bin/secret**

Run:

```bash
K=$(bin/secret KANEO_TOKEN "op://tinkerex/kaneo key/credential") && \
  curl -s -o /dev/null -w "authed: %{http_code}\n" --max-time 10 \
  -H "Authorization: Bearer $K" http://kaneo.home/api/auth/get-session
```

Expected: `authed: 200`. A `401` means the key or the header format is wrong — resolve it here,
before any code depends on it.

- [ ] **Step 11: Commit the lockdown edit**

```bash
git add ops/kaneo-stack.yml
git commit -m "Kaneo: registration and guest access closed after the admin signup"
```

---

# Phase B — Probe the live API

> Nothing below this line writes to Forgejo or to the real Kaneo project. Both tasks work in a
> throwaway workspace/project that Task 8 does not reuse.

### Task 3: The probe harness

**Files:**
- Create: `bin/migrate-record`

- [ ] **Step 1: Write the skeleton**

Same constraints as `bin/log` and for the same reasons (§14j): **no bundler, no Rails, stdlib only**,
and `Encoding.default_external` set before anything reads a subprocess.

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# ONE-TIME MIGRATION TOOL: Forgejo -> Kaneo. Deleted once the cutover is verified (see the plan's
# final task); it is committed in between so the import is reviewable and re-runnable.
#
# NO BUNDLER, NO RAILS, STDLIB ONLY — the same rule bin/log carries, for the same reason (§14j): an
# inherited BUNDLE_GEMFILE/RUBYOPT from a bundled parent makes a gem-loading child boot against the
# wrong Gemfile. Loading no gem means a fresh clone, a worktree and a cloud session all run it.
require "json"
require "net/http"
require "open3"
require "uri"

# Captured subprocess output is tagged with the default external encoding, US-ASCII whenever
# LANG/LC_ALL is unset. The record's titles are full of em dashes. Same fix bin/log carries.
Encoding.default_external = Encoding::UTF_8

module Migrate
  module_function

  FORGEJO_URL   = ENV.fetch("FORGEJO_URL", "http://forgejo.home")
  FORGEJO_OWNER = ENV.fetch("FORGEJO_OWNER", "chaim354")
  FORGEJO_REPO  = ENV.fetch("FORGEJO_REPO", "tinkerex")
  KANEO_URL     = ENV.fetch("KANEO_URL", "http://kaneo.home")

  FORGEJO_TOKEN_REF = "op://tinkerex/forgejo key/credential"
  KANEO_TOKEN_REF   = "op://tinkerex/kaneo key/credential"

  class Failed < StandardError; end

  def secret(name, ref)
    out, err, status = Open3.capture3(File.expand_path("secret", __dir__), name, ref)
    raise Failed, "could not resolve #{name} from #{ref}: #{err.strip}" if !status.success? || out.empty?

    out.chomp
  end

  def forgejo_token = @forgejo_token ||= secret("FORGEJO_TOKEN", FORGEJO_TOKEN_REF)
  def kaneo_token   = @kaneo_token   ||= secret("KANEO_TOKEN", KANEO_TOKEN_REF)

  # ONE REQUEST METHOD FOR BOTH SERVERS, differing only in the Authorization header — Forgejo takes
  # `token <t>`, Kaneo takes `Bearer <t>`. Keeping them in one place is what stops a later edit from
  # sending a Forgejo-shaped header to Kaneo and reading the 401 as a bad key.
  def request(base, auth, method, path, body = nil)
    uri = URI.parse("#{base.chomp('/')}#{path}")
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post,
              put: Net::HTTP::Put, patch: Net::HTTP::Patch }.fetch(method)
    req = klass.new(uri)
    req["Authorization"] = auth
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(body) if body

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                              open_timeout: 5, read_timeout: 30) { |h| h.request(req) }
    code = res.code.to_i
    raise Failed, "HTTP #{res.code} from #{method.upcase} #{path}: #{res.body.to_s[0, 300]}" unless code.between?(200, 299)

    res.body.to_s.empty? ? nil : JSON.parse(res.body)
  end

  def forgejo(method, path, body = nil)
    request(FORGEJO_URL, "token #{forgejo_token}", method, "/api/v1/repos/#{FORGEJO_OWNER}/#{FORGEJO_REPO}#{path}", body)
  end

  def kaneo(method, path, body = nil)
    request(KANEO_URL, "Bearer #{kaneo_token}", method, "/api#{path}", body)
  end
end
```

- [ ] **Step 2: Make it executable and verify both servers answer**

```bash
chmod +x bin/migrate-record
```

Append a temporary `main` that pings both, run it, then remove it — or verify inline:

```bash
ruby -c bin/migrate-record && ruby -E UTF-8:UTF-8 -e 'load "./bin/migrate-record"; puts Migrate.workspace_id'
```

Expected: `Syntax OK` then the workspace id. **`load`, not `require`** — `require` appends `.rb` to a
path that has no extension and fails with a LoadError that reads like a missing file.

- [ ] **Step 3: Commit**

```bash
git add bin/migrate-record && chmod +x bin/migrate-record
git commit -m "Migration harness: one request method, two auth headers"
```

---

### Task 4: Probe the counter — the assumption the whole design rests on

**Files:**
- Modify: `bin/migrate-record`

This is the gate. The number-preserving import assumes Kaneo's per-project counter **starts at 1,
increments by exactly one per created task, and does not reuse a deleted task's number.** None of
that is in the OpenAPI spec. §15: probe, do not reason.

- [ ] **Step 1: Add workspace and project discovery**

The workspace is a better-auth organization (`/auth/organization/list`), and `POST /project` needs a
`workspaceId`. Both response shapes are unverified, so this step *reports* them rather than assuming:

```ruby
  def probe_context
    orgs = kaneo(:get, "/auth/organization/list")
    warn "organizations: #{JSON.pretty_generate(orgs)}"
    projects = kaneo(:get, "/project")
    warn "projects: #{JSON.pretty_generate(projects)}"
    [ orgs, projects ]
  end
```

- [ ] **Step 2: Run it and record what came back**

```bash
ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.probe_context\' 2>&1 | head -60
```

Expected: two JSON blobs. **Write down the field that holds the organization id and the shape of the
project list** — every later step uses them. If `/auth/organization/list` returns `[]`, create a
workspace in the Kaneo UI first; the API for it is better-auth's `POST /auth/organization/create`,
but doing it in the UI once is cheaper than probing that too.

- [ ] **Step 3: Write the counter probe**

```ruby
  # THE ASSUMPTION UNDER THE WHOLE MIGRATION, MEASURED RATHER THAN ARGUED. Creates a throwaway
  # project, makes three tasks, deletes the middle one, makes a fourth, and prints the numbers. The
  # import in Task 8 is only safe if this prints 1, 2, 3 and then 4 — a reused number means a
  # placeholder could be silently consumed and every issue after it shifted by one.
  def probe_counter(workspace_id)
    project = kaneo(:post, "/project", { name: "counter probe", workspaceId: workspace_id,
                                         icon: "Beaker", slug: "counter-probe-#{Time.now.to_i}" })
    pid = project.fetch("id")
    warn "probe project: #{pid}"

    made = (1..3).map do |i|
      t = kaneo(:post, "/task/#{pid}", { title: "probe #{i}", description: "",
                                         priority: "no-priority", status: "To Do" })
      warn "  created title=#{t['title']} number=#{t['number'].inspect} id=#{t['id']}"
      t
    end

    kaneo(:delete, "/task/#{made[1].fetch('id')}")
    warn "  deleted the second task (number #{made[1]['number'].inspect})"

    fourth = kaneo(:post, "/task/#{pid}", { title: "probe 4", description: "",
                                            priority: "no-priority", status: "To Do" })
    warn "  created title=#{fourth['title']} number=#{fourth['number'].inspect} id=#{fourth['id']}"

    warn ""
    warn "VERDICT: numbers were #{made.map { |t| t['number'] }.inspect} then #{fourth['number'].inspect}"
    warn "PASS requires [1, 2, 3] then 4. Anything else stops the migration."
    warn "Delete the probe project in the UI when you are done reading this."
  end
```

`:delete` is not in `request`'s method table yet — add it:

```ruby
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put,
              patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.fetch(method)
```

- [ ] **Step 4: Run the probe**

```bash
ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.probe_counter(ENV.fetch("WS"))\' WS=<workspace-id-from-step-2>
```

(Set `WS` as an environment variable: `WS=<id> ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.probe_counter(ENV.fetch("WS"))\'`)

Expected: `VERDICT: numbers were [1, 2, 3] then 4`.

- [ ] **Step 5: Decide**

**If the verdict is `[1, 2, 3]` then `4`** — the design holds. Continue to Task 5.

**If numbers do not start at 1, skip, or the fourth reuses 2** — STOP. Do not import. Record what was
observed and re-open the design; the fallback (let Kaneo renumber, then mechanically rewrite the 129
citations and 50 body cross-refs) is still fully available and nothing has been lost. That is the
entire reason this task comes before Task 5 rather than after.

**If `number` comes back `nil`** — the schema marks it nullable. Find out when it is populated before
going further; a null number is not a number the record can cite.

- [ ] **Step 6: Delete the probe project (human, browser), then commit**

```bash
git add bin/migrate-record
git commit -m "Probe: Kaneo's per-project counter, measured before anything depends on it"
```

---

### Task 5: Probe the wire for every verb `bin/log` needs

**Files:**
- Modify: `bin/migrate-record`

`bin/log`'s label-id bug shipped because a wire contract was asserted and the stub agreed with the
assertion. This task observes each contract against the live server so the code in Phase D is written
against something real. The untyped one matters most: the OpenAPI declares
`GET /task/tasks/{projectId}` as bare `{"type":"object"}`, and that is the endpoint the number→id
resolver depends on.

- [ ] **Step 1: Write the verb probe**

```ruby
  # SIX CONTRACTS, OBSERVED. Each `warn` is the evidence a Phase D implementation is written against.
  # The list endpoint is the one that matters most: its OpenAPI response type is bare "object", so
  # its envelope (a bare array? {tasks:[...]}? {data:[...]}?) is genuinely unknown until seen.
  def probe_verbs(workspace_id)
    project = kaneo(:post, "/project", { name: "verb probe", workspaceId: workspace_id,
                                         icon: "Beaker", slug: "verb-probe-#{Time.now.to_i}" })
    pid = project.fetch("id")

    # THE WORKSPACE IS ALREADY KNOWN: `tinkerex`, id lIN1YZezsLM0qqD9UncNSoWhznwliar7, measured
    # 2026-08-31 via GET /api/auth/organization/list. It is passed in rather than discovered.
    warn "== columns (what `status` strings does a new project have?)"
    warn JSON.pretty_generate(kaneo(:get, "/column/#{pid}"))

    task = kaneo(:post, "/task/#{pid}", { title: "verb probe", description: "body text",
                                          priority: "no-priority", status: "To Do" })
    tid = task.fetch("id")
    warn "== create task"
    warn JSON.pretty_generate(task)

    warn "== LIST TASKS — the untyped one. What is the envelope?"
    warn JSON.pretty_generate(kaneo(:get, "/task/tasks/#{pid}?limit=200"))

    warn "== label create (does taskId on create attach it?)"
    label = kaneo(:post, "/label", { name: "arc", color: "#666666", workspaceId: workspace_id, taskId: tid })
    warn JSON.pretty_generate(label)
    warn "== labels on the task"
    warn JSON.pretty_generate(kaneo(:get, "/label/task/#{tid}"))
    warn "== labels in the workspace (is the name reusable, or is a row per task?)"
    warn JSON.pretty_generate(kaneo(:get, "/label/workspace/#{workspace_id}"))

    warn "== comment"
    warn JSON.pretty_generate(kaneo(:post, "/comment/#{tid}", { content: "a correction" }))

    warn "== status change (close)"
    warn JSON.pretty_generate(kaneo(:put, "/task/status/#{tid}", { status: "Done" }))

    warn "== search"
    warn JSON.pretty_generate(kaneo(:get, "/search?q=verb+probe&projectId=#{pid}"))

    warn ""
    warn "Delete the verb-probe project in the UI when you are done reading this."
  end
```

- [ ] **Step 2: Run it and save the output as the reference**

```bash
mkdir -p tmp/kaneo-probe
WS=<workspace-id> ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.probe_verbs(ENV.fetch("WS"))\' 2>tmp/kaneo-probe/verbs.txt
wc -l tmp/kaneo-probe/verbs.txt
```

Expected: a non-empty file with nine labelled sections. **Read it.** Four questions must be answered
before Phase D, and each has a concrete consequence:

1. **What envelope does `GET /task/tasks/{projectId}` return?** Determines the number→id resolver.
2. **What `status` strings does a fresh project's board use?** `bin/log close` must send one that
   exists. `"Done"` is a guess until this says otherwise.
3. **Does `POST /label` with `taskId` attach in one call, or is `PUT /label/{id}/task` also needed?**
   Determines whether task creation is one wire call or two, and therefore whether a task can exist
   unlabelled after a partial failure.
4. **Is a workspace label reusable across tasks, or is there one row per task?** The schema's
   nullable `taskId` on a label row suggests the latter, which would change what `bin/log setup`
   means.

- [ ] **Step 3: Record the answers in the plan**

Write the four answers into this task as a comment block before continuing, so Phase D is not written
from memory of a terminal that has since scrolled.

- [ ] **Step 4: Delete the verb-probe project (human, browser), then commit**

```bash
git add bin/migrate-record
git commit -m "Probe: the six wire contracts bin/log will depend on"
```

---

# Phase C — Migrate the data

### Task 6: Export Forgejo, verified

**Files:**
- Modify: `bin/migrate-record`

> **On the ordering.** The spec says "export first, before anything is created". This task sits after
> Phase A and B because **nothing in Tasks 1–5 touches Forgejo at all** — they deploy Kaneo and probe
> it in throwaway projects. What the spec's rule actually guards is doing something irreversible to
> Forgejo without a copy, and the only such step is Task 20. The export still lands well before the
> import in Task 8, which is the first step that depends on it. **Run it earlier anyway if Forgejo's
> health is in any doubt** — it costs one command and needs nothing from Kaneo.

- [ ] **Step 1: Write the export**

```ruby
  # THE EXPORT IS THE SAFETY NET AND RUNS BEFORE ANYTHING IS CREATED OR DELETED. Forgejo was never
  # covered by ops/backup-db.sh (it knows only chunk|share|s3|sync), so the live instance is the only
  # copy of the record until this file exists. Everything after this step is redoable from it.
  #
  # PAGINATED AT 50, NOT 200. Forgejo CLAMPS limit to 50 and returns a full-looking page — measured:
  # limit=200 returned exactly 50 of 186 with no indication it had truncated. A loop that trusts one
  # page silently exports 27% of the record.
  def export(path = "tmp/forgejo-export.json")
    issues = []
    page = 1
    loop do
      batch = forgejo(:get, "/issues?state=all&type=issues&limit=50&page=#{page}")
      break if batch.nil? || batch.empty?

      issues.concat(batch)
      page += 1
    end
    issues.uniq! { |i| i["number"] }

    # COMMENTS ARE FETCHED PER ISSUE, and only where the issue says it has some. `comments` is a
    # COUNT on the issue object, so this asks for the 21 that have any rather than 186 round trips.
    with_comments = issues.count { |i| i["comments"].to_i > 0 }
    warn "fetching comments for #{with_comments} issues"
    issues.each do |issue|
      issue["_comments"] = issue["comments"].to_i.zero? ? [] : forgejo(:get, "/issues/#{issue['number']}/comments")
    end

    File.write(path, JSON.pretty_generate(issues))
    warn "wrote #{path}: #{issues.size} issues, #{issues.sum { |i| i['_comments'].size }} comments"
    issues
  end
```

- [ ] **Step 2: Run the export**

```bash
mkdir -p tmp && ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.export\'
```

Expected: `wrote tmp/forgejo-export.json: 186 issues, 30 comments`.

- [ ] **Step 3: Verify the export against the live API rather than against itself**

```ruby
  # VERIFIES AGAINST THE SERVER, NOT AGAINST THE FILE'S OWN CONTENTS. "The file has 186 entries"
  # is a claim the file makes about itself; "the server says 186 and the file has the same 186
  # numbers" is a fact. §15: a guard that cannot fail has not been shown to work.
  def verify_export(path = "tmp/forgejo-export.json")
    issues = JSON.parse(File.read(path))
    numbers = issues.map { |i| i["number"] }.sort

    # X-Total-Count IS A HEADER, so this cannot go through `request`, which returns parsed JSON and
    # throws the response away. A raw call is the honest way to read it rather than bending the
    # shared helper to return two different things.
    uri = URI.parse(FORGEJO_URL)
    live = Net::HTTP.start(uri.host, uri.port) do |http|
      req = Net::HTTP::Get.new("/api/v1/repos/#{FORGEJO_OWNER}/#{FORGEJO_REPO}/issues?state=all&type=issues&limit=1")
      req["Authorization"] = "token #{forgejo_token}"
      http.request(req)["x-total-count"].to_i
    end

    problems = []
    problems << "count: file has #{issues.size}, server says #{live}" unless issues.size == live
    problems << "duplicate numbers" unless numbers.uniq.size == numbers.size
    empty = issues.select { |i| i["title"].to_s.strip.empty? }
    problems << "#{empty.size} issues with an empty title" if empty.any?

    if problems.empty?
      warn "export verified: #{issues.size} issues, numbers #{numbers.first}-#{numbers.last}, " \
           "gaps #{((numbers.first..numbers.last).to_a - numbers).inspect}"
    else
      problems.each { |p| warn "!! #{p}" }
      raise Failed, "export did not verify"
    end
  end
```

- [ ] **Step 4: Run the verification**

```bash
ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.verify_export\'
```

Expected: `export verified: 186 issues, numbers 6-193, gaps [116, 117]`.

- [ ] **Step 5: Archive the export off-box**

Copy `tmp/forgejo-export.json` somewhere that is not this machine and not the Unraid box. **This is
the only safety net for the whole migration** and `tmp/` is gitignored and routinely swept.

- [ ] **Step 6: Commit the tooling (not the export)**

```bash
git add bin/migrate-record
git commit -m "Export Forgejo, verified against the server's own count"
```

---

### Task 7: Create the real project and its labels

**Files:**
- Modify: `bin/migrate-record`

- [ ] **Step 1: Write project and label creation**

```ruby
  LABELS = %w[arc open-work deploy blocked deliberate
              filelayer library-scan addons previews maker-web ci].freeze

  # ONE PROJECT, AND THAT IS FORCED RATHER THAN CHOSEN. Kaneo's task counter is PER PROJECT, so
  # splitting arcs / open-work / deploys into three projects would shatter tinkerex#N into three
  # sequences and break all 129 citations in the tree. The slug is what bin/log resolves by.
  def create_project(workspace_id, slug: "tinkerex")
    project = kaneo(:post, "/project", { name: "tinkerex", workspaceId: workspace_id,
                                         icon: "Wrench", slug: slug })
    warn "project #{project['slug']} id=#{project['id']}"
    project
  end

  def create_labels(workspace_id)
    LABELS.each do |name|
      kaneo(:post, "/label", { name: name, color: "#666666", workspaceId: workspace_id })
    end
    present = kaneo(:get, "/label/workspace/#{workspace_id}")
    warn "labels now present: #{present.map { |l| l['name'] }.sort.inspect}"
    raise Failed, "labels missing" unless (LABELS - present.map { |l| l["name"] }).empty?
  end
```

**Adjust `create_labels` to whatever Task 5 step 3 recorded** about label reuse. If a label row is
per-task rather than per-workspace, this method creates the *vocabulary* and the import attaches per
task; if labels are reusable, it creates them once and the import references them by id.

- [ ] **Step 2: Run it**

```bash
WS=<workspace-id> ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; p Migrate.create_project(ENV.fetch("WS")); Migrate.create_labels(ENV.fetch("WS"))\'
```

Expected: the project id printed, and all eleven label names listed. **Record the project id** — Task 8
needs it.

- [ ] **Step 3: Commit**

```bash
git add bin/migrate-record
git commit -m "Create the tinkerex project and its eleven labels"
```

---

### Task 8: The number-preserving import

**Files:**
- Modify: `bin/migrate-record`

- [ ] **Step 1: Write the import**

```ruby
  # THE PLACEHOLDERS ARE THE WHOLE TRICK. Forgejo numbers 6-193 with holes at 116 and 117; Kaneo
  # counts from 1. Creating a throwaway task for each number the record does not use puts every real
  # issue on its own number, so all 129 tinkerex#N citations in the tree and the 50 inside issue
  # bodies keep resolving with no rewrite at all.
  #
  # PLACEHOLDERS ARE NEVER DELETED. Task 4 measured whether a deleted number is reused; even where
  # it is not, deleting them turns a visible, explained hole into an invisible one, and a later
  # reader who deletes a "junk" task could shift every number after it. A hole you can see is safer
  # than a shift you cannot.
  #
  # STRICTLY SEQUENTIAL, NEVER CONCURRENT. The counter is atomic but the ORDER of concurrent creates
  # is not, and this loop's correctness is entirely "the Nth create gets number N".
  def import(project_id, path = "tmp/forgejo-export.json")
    issues = JSON.parse(File.read(path)).sort_by { |i| i["number"] }
    by_number = issues.to_h { |i| [ i["number"], i ] }
    last = issues.last["number"]
    created = {}

    (1..last).each do |n|
      issue = by_number[n]

      task = if issue
        kaneo(:post, "/task/#{project_id}", {
          title: issue["title"],
          description: issue["body"].to_s,
          priority: "no-priority",
          status: issue["state"] == "closed" ? "Done" : "Open"
        })
      else
        kaneo(:post, "/task/#{project_id}", {
          title: "(reserved ##{n})",
          description: "Placeholder. Forgejo had no issue ##{n}; this task exists so every later " \
                       "issue keeps its original number. Do not delete.",
          priority: "no-priority",
          status: "Done"
        })
      end

      # FAIL AT THE FIRST DRIFT, NOT AT THE END. If number N did not come back as N, every task
      # after it would be wrong too, and a loop that carried on would produce 186 wrong rows and one
      # confusing report. Stop here: the project is deleted and the import re-run from the export.
      got = task["number"]
      raise Failed, "drift at #{n}: Kaneo assigned #{got.inspect} (delete the project and re-run)" unless got == n

      created[n] = task["id"]
      warn "  #{n}/#{last}" if (n % 25).zero?
    end

    File.write("tmp/kaneo-ids.json", JSON.pretty_generate(created))
    warn "imported #{created.size} tasks (#{issues.size} real, #{created.size - issues.size} placeholders)"
    created
  end
```

**Adjust the two `status:` values** to whatever column names Task 5 step 3 recorded. `"Open"` and
`"Done"` are the intent; the strings must be ones the board actually has.

- [ ] **Step 2: Run the import**

```bash
PID=<project-id> ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.import(ENV.fetch("PID"))\'
```

Expected: `imported 193 tasks (186 real, 7 placeholders)` — 193 numbers, 186 issues, placeholders at
1–5, 116, 117.

- [ ] **Step 3: If it raised `drift at N`, reset and retry**

Delete the project in the Kaneo UI, re-run Task 7 step 2, then this task. The export makes this cheap
and it is the designed recovery, not a failure state.

- [ ] **Step 4: Attach the labels**

```ruby
  # LABELS ARE A SECOND CALL, because POST /task/{projectId} has no labels field. That makes creation
  # non-atomic in a way Forgejo's was not: a task can exist unlabelled if this fails. Reported, never
  # swallowed — an arc with no `arc` label is invisible to every search that filters by kind.
  def attach_labels(workspace_id, path = "tmp/forgejo-export.json", ids = "tmp/kaneo-ids.json")
    issues = JSON.parse(File.read(path))
    created = JSON.parse(File.read(ids))
    failures = []

    issues.each do |issue|
      task_id = created.fetch(issue["number"].to_s)
      issue["labels"].each do |label|
        kaneo(:post, "/label", { name: label["name"], color: "#666666",
                                 workspaceId: workspace_id, taskId: task_id })
      rescue Failed => e
        failures << "##{issue['number']} #{label['name']}: #{e.message}"
      end
    end

    failures.each { |f| warn "!! #{f}" }
    raise Failed, "#{failures.size} label attachments failed" if failures.any?

    warn "attached labels to #{issues.size} tasks"
  end
```

- [ ] **Step 5: Run it**

```bash
WS=<workspace-id> ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.attach_labels(ENV.fetch("WS"))\'
```

Expected: `attached labels to 186 tasks`.

- [ ] **Step 6: Commit**

```bash
git add bin/migrate-record
git commit -m "Import 186 issues at their original numbers, 7 placeholders for the gaps"
```

---

### Task 9: Verify the import, then import the comments

**Files:**
- Modify: `bin/migrate-record`

- [ ] **Step 1: Write the verification**

```ruby
  # READ-BACK VERIFICATION, NOT A REPORT ON WHAT WE SENT. The import already checked each number as
  # it went; this asks the server, independently, what it now holds. The two can disagree — a task
  # created and then altered, a partial run resumed by hand — and only this one would notice.
  def verify_import(project_id, path = "tmp/forgejo-export.json")
    issues = JSON.parse(File.read(path))
    listed = kaneo(:get, "/task/tasks/#{project_id}?limit=500")
    tasks = listed.is_a?(Array) ? listed : listed.fetch("tasks")
    by_number = tasks.to_h { |t| [ t["number"], t ] }

    problems = []
    issues.each do |issue|
      task = by_number[issue["number"]]
      next problems << "##{issue['number']} missing from Kaneo" if task.nil?

      problems << "##{issue['number']} title: #{task['title'].inspect} != #{issue['title'].inspect}" \
        unless task["title"] == issue["title"]
    end

    if problems.empty?
      warn "verified #{issues.size} issues present at their original numbers"
    else
      problems.first(20).each { |p| warn "!! #{p}" }
      raise Failed, "#{problems.size} problems"
    end
  end
```

- [ ] **Step 2: Run it**

```bash
PID=<project-id> ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.verify_import(ENV.fetch("PID"))\'
```

Expected: `verified 186 issues present at their original numbers`.

- [ ] **Step 3: Import the comments**

```ruby
  # COMMENTS LAST, because they need the task ids the import produced. A correction is a comment and
  # never an edit (bin/log's own rule), so the record's corrections only survive if this runs.
  def import_comments(path = "tmp/forgejo-export.json", ids = "tmp/kaneo-ids.json")
    issues = JSON.parse(File.read(path))
    created = JSON.parse(File.read(ids))
    count = 0

    issues.each do |issue|
      issue["_comments"].to_a.each do |comment|
        kaneo(:post, "/comment/#{created.fetch(issue['number'].to_s)}", { content: comment["body"].to_s })
        count += 1
      end
    end
    warn "imported #{count} comments"
    count
  end
```

- [ ] **Step 4: Run it**

```bash
ruby -E UTF-8:UTF-8 -e \'load "./bin/migrate-record"; Migrate.import_comments\'
```

Expected: `imported 30 comments`.

- [ ] **Step 5: Spot-check a cited issue by hand**

```bash
K=$(bin/secret KANEO_TOKEN "op://tinkerex/kaneo key/credential")
curl -s -H "Authorization: Bearer $K" "http://kaneo.home/api/task/tasks/<project-id>?limit=500" \
  | ruby -E UTF-8:UTF-8 -rjson -e 'd=JSON.parse($stdin.read); t=(d.is_a?(Array) ? d : d["tasks"]); x=t.find{|i| i["number"]==178}; puts "#178: #{x&.dig("title").inspect}"'
```

Expected: the title of `tinkerex#178`, which CLAUDE.md cites as the staging-panel arc. **This is the
citation-preservation claim, checked directly rather than inferred.**

- [ ] **Step 6: Commit**

```bash
git add bin/migrate-record
git commit -m "Verify the import by read-back, then import the 30 comments"
```

---

# Phase D — Repoint bin/log

### Task 10: Rename the stub, no behaviour change

**Files:**
- Create: `test/support/stub_kaneo.rb` (from `test/support/stub_forgejo.rb`)
- Delete: `test/support/stub_forgejo.rb`
- Modify: `test/log_cli_test.rb`

The stub records requests verbatim and models no server, so this is a rename plus a comment pass —
kept as its own commit so the next task's diff is only about Kaneo.

- [ ] **Step 1: Rename the file and the class**

```bash
git mv test/support/stub_forgejo.rb test/support/stub_kaneo.rb
sed -i '' 's/StubForgejo/StubKaneo/g; s/Forgejo/Kaneo/g' test/support/stub_kaneo.rb test/log_cli_test.rb
```

- [ ] **Step 2: Fix the default response, which is Forgejo-shaped**

The stub's default `response:` is an issue (`number`/`title`/`state`/`body`). Kaneo returns a task:

```ruby
  def initialize(status: 201, response: { "id" => "task_stub", "number" => 42, "title" => "stub",
                                          "status" => "Open", "description" => "" },
                 routes: {})
```

- [ ] **Step 3: Rename the harness's own environment names**

`run_log` pins `FORGEJO_URL` to an unroutable address so that **touching the network is opt-in** — left
at `bin/log`'s own default, a test that merely forgot to override it would POST a real issue into the
live instance from anywhere on the LAN. That guard has to keep working under the new name, and the
Step 1 sed is case-sensitive so it did not touch the SHOUTING form:

```ruby
    base = cleared.merge("KANEO_URL" => "http://127.0.0.1:1", "LOG_SPOOL_DIR" => @spool)
```

`LABEL_FIXTURE` also encodes a Forgejo fact — int64 label ids, because issue-create refused names.
Kaneo attaches labels by a separate call and takes the name directly, so the fixture becomes the
shape `GET /label/workspace/:id` returns:

```ruby
  # WHAT THE LIVE INSTANCE RETURNS — observed in the plan's Task 5, not assumed. Kaneo labels carry a
  # string id and are attached by a second call rather than inline on create, so unlike Forgejo's
  # int64 ids these are never sent back in a task-create payload.
  LABEL_FIXTURE = LABEL_NAMES.each_with_index.map { |n, i| { "id" => "lbl#{i + 1}", "name" => n } }.freeze
```

- [ ] **Step 4: Run the suite to see what the rename left behind**

Run: `bin/rails test test/log_cli_test.rb`
Expected: FAIL. The tests still assert Forgejo paths and payloads; the next tasks fix them. **Record
the failure count** — it is the budget the rest of Phase D burns down.

- [ ] **Step 5: Commit the rename alone**

```bash
git add -A test/support test/log_cli_test.rb
git commit -m "Rename the stub: it modelled no server, so this is a rename"
```

---

### Task 11: The transport — URL, token, Bearer, project resolution

**Files:**
- Modify: `bin/log:96-100, 116-182`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  test "every request carries a Bearer token and reaches the /api prefix" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, [ { "id" => "t1", "number" => 7, "title" => "x", "status" => "Open" } ] ]
    })
    out, err, code = run_log("show", "7", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "secret-key" })

    assert_equal 0, code, err
    stub.requests.each do |request|
      assert_equal "Bearer secret-key", request.headers["authorization"]
      assert request.path.start_with?("/api/"), "#{request.path} is not under /api"
    end
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/log_cli_test.rb -n "/Bearer token/"`
Expected: FAIL — `bin/log` still sends `token ...` and builds Forgejo paths.

- [ ] **Step 3: Replace the config and path builders**

```ruby
  # THE VAULT ITEM IS "kaneo key" AND THE TOKEN LIVES IN ITS `credential` FIELD, matching the shape
  # the Forgejo item used. CLAUDE.md §13 must name this same reference — the two disagreed under
  # Forgejo (the doc said op://tinkerex/Forgejo/token, the code read op://tinkerex/forgejo key/
  # credential) and only one of them could ever have been right.
  TOKEN_REF = "op://tinkerex/kaneo key/credential"

  def kaneo_url      = ENV.fetch("KANEO_URL", "http://kaneo.home")
  def workspace_slug = ENV.fetch("KANEO_WORKSPACE", "tinkerex")
  def project_slug   = ENV.fetch("KANEO_PROJECT", "tinkerex")

  # THE SLUGS ARE CONFIG; THE IDS ARE RESOLVED. Every Kaneo path takes an opaque id, but putting one
  # in an env default would mean a fresh clone cannot run bin/log at all — which is exactly what
  # FORGEJO_OWNER/FORGEJO_REPO's human-readable defaults bought. Both lookups are memoized for the
  # process, mirroring label_index's existing shape.
  #
  # TWO LOOKUPS, NOT ONE, AND THE ORDER IS FORCED. The obvious design reads GET /api/project once and
  # takes `workspaceId` off the project record — but **GET /api/project REFUSES to answer without a
  # workspaceId query param** (measured: 400, "Invalid key: Expected \"workspaceId\" but received
  # undefined"). So the project list cannot be the thing that tells you the workspace; the workspace
  # must be resolved first, from better-auth's own organization list. A workspace in Kaneo IS a
  # better-auth organization — there is no /api/workspace collection to list.
  def workspace_id
    @workspace_id ||= begin
      path = "/api/auth/organization/list"
      orgs = parse(api(:get, path), path)
      found = orgs.find { |o| o["slug"] == workspace_slug }
      raise Unreachable, "no workspace with slug #{workspace_slug.inspect} (set KANEO_WORKSPACE)" unless found

      found.fetch("id")
    end
  end

  def project_id
    @project_id ||= begin
      path = "/api/project?workspaceId=#{workspace_id}"
      body = parse(api(:get, path), path)
      list = body.is_a?(Array) ? body : body.fetch("projects", [])
      found = list.find { |p| p["slug"] == project_slug }
      raise Unreachable, "no project with slug #{project_slug.inspect} (set KANEO_PROJECT)" unless found

      found.fetch("id")
    end
  end
```

- [ ] **Step 4: Swap the header and the URL builder in `perform`**

In `perform`, replace the base and the Authorization header, and add the PUT and DELETE verbs Kaneo
needs (`close` is a PUT to `/task/status/:id`, not a PATCH to an issue):

```ruby
    uri = URI.parse("#{kaneo_url.chomp('/')}#{path}")
    raise UsageError, "KANEO_URL has no scheme or host: #{kaneo_url.inspect}" unless uri.host

    request = case method
    when :get   then Net::HTTP::Get.new(uri)
    when :post  then Net::HTTP::Post.new(uri)
    # PUT, NOT PATCH. Forgejo closed an issue by PATCHing its state; Kaneo moves a task to a column
    # with PUT /task/status/:id. Keeping the verb here rather than in `close` is what makes the
    # Authorization header, the timeouts and the Unreachable mapping impossible to bypass.
    when :put   then Net::HTTP::Put.new(uri)
    else raise ArgumentError, "unsupported method #{method.inspect}"
    end

    request["Authorization"] = "Bearer #{token}"
```

Also update the `Unreachable` message in `api`'s rescue from `forgejo_url` to `kaneo_url`.

- [ ] **Step 5: Run the test**

Run: `bin/rails test test/log_cli_test.rb -n "/Bearer token/"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log talks to Kaneo: Bearer auth, /api paths, project resolved by slug"
```

---

### Task 12: Number → id resolution

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

Kaneo addresses tasks by an opaque `id`; the citable `number` is not addressable. `show`, `note` and
`close` all need this, and Forgejo needed nothing like it.

- [ ] **Step 1: Write the failing test**

```ruby
  test "a number resolves to the task id before any addressed call is made" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, [ { "id" => "abc", "number" => 178, "title" => "Staging panel", "status" => "Done" } ] ]
    })
    out, err, code = run_log("show", "178", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    assert_match(/#178 Staging panel/, out)
  ensure
    stub&.shutdown
  end

  test "a number that no task carries is a clear refusal, not a crash" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, [] ]
    })
    _out, err, code = run_log("show", "999", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 3, code
    assert_match(/no issue #999/, err)
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify both fail**

Run: `bin/rails test test/log_cli_test.rb -n "/resolves to the task id|no task carries/"`
Expected: FAIL.

- [ ] **Step 3: Implement the resolver**

```ruby
  # THE MAP IS FETCHED ONCE PER PROCESS, not once per lookup — `close` takes several numbers and the
  # unit of work is "this branch is done", so a per-number GET would be one full list per issue.
  #
  # THE ENVELOPE IS ACCEPTED IN BOTH SHAPES DELIBERATELY. GET /task/tasks/:projectId is declared in
  # Kaneo's OpenAPI as a bare `{"type":"object"}` — no properties at all — so the response was
  # OBSERVED rather than read (see the plan's Task 5). Tolerating an array or a {tasks:[...]} wrapper
  # costs one line and removes the one place a version bump could silently return nothing.
  def task_index
    @task_index ||= begin
      path = "/api/task/tasks/#{project_id}?limit=500"
      body = parse(api(:get, path), path)
      list = body.is_a?(Array) ? body : body.fetch("tasks", [])
      list.to_h { |t| [ t["number"], t ] }
    end
  end

  # RAISES Unreachable, NOT UsageError. The number is well-formed — issue_number! already rejected a
  # traversal attempt — so this is "the record does not have that", which is the same class of answer
  # as a 404 from Forgejo's own issue endpoint and must spool nothing on a read.
  def task_for(number)
    task_index[number.to_i] or raise Unreachable, "no issue ##{number} in #{project_slug}"
  end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/log_cli_test.rb -n "/resolves to the task id|no task carries/"`
Expected: PASS.

- [ ] **Step 5: Mutation-check the resolver**

§15 requires it. Change `list.to_h { |t| [ t["number"], t ] }` to key on `t["id"]` and re-run.
Expected: the first test goes RED (no task found for 178). Restore.

- [ ] **Step 6: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "Resolve a citable number to Kaneo's opaque task id"
```

---

### Task 13: `show` and `search`

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing test for search**

```ruby
  test "search asks Kaneo's search endpoint, scoped to the project, and percent-encodes the query" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /search" => [ 200, { "tasks" => [ { "number" => 12, "title" => "a & b", "status" => "Done" } ] } ]
    })
    out, err, code = run_log("search", "a & b", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    search = stub.requests.find { |r| r.path.include?("/search") }
    assert_includes search.path, "q=a+%26+b"
    assert_includes search.path, "projectId=p1"
    assert_match(/#12 \[Done\] a & b/, out)
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/log_cli_test.rb -n "/search asks Kaneo/"`
Expected: FAIL.

- [ ] **Step 3: Implement both read verbs**

```ruby
  def show(argv)
    number = issue_number!(argv.shift or raise UsageError, "show needs an issue number")
    task = task_for(number)

    puts "##{task['number']} #{task['title']} [#{task['status']}]"
    puts
    puts task["description"]
    EXIT_OK
  end

  # SCOPED TO THE PROJECT. Kaneo's search is global across every workspace the key can see; without
  # projectId a query would return tasks from any other project on the instance as though they were
  # part of the record. Forgejo's equivalent was scoped by construction — the path named the repo.
  def search(argv)
    query = argv.shift or raise UsageError, "search needs a query"
    path = "/api/search?q=#{URI.encode_www_form_component(query)}&projectId=#{project_id}&limit=100"
    body = parse(api(:get, path), path)
    tasks = body.is_a?(Array) ? body : body.fetch("tasks", [])

    if tasks.empty?
      puts "bin/log: no issues matching #{query.inspect}."
    else
      tasks.each { |t| puts "##{t['number']} [#{t['status']}] #{t['title']}" }
    end
    EXIT_OK
  end
```

- [ ] **Step 4: Run the read-verb tests**

Run: `bin/rails test test/log_cli_test.rb -n "/search|show/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "show and search read from Kaneo, scoped to the project"
```

---

### Task 14: `setup` and task creation with labels

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  test "creating an arc posts the task, then attaches the label, and reports the number" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "POST /task/p1" => [ 201, { "id" => "t9", "number" => 194, "title" => "An arc", "status" => "Open" } ],
      "POST /label" => [ 201, { "id" => "l1", "name" => "arc" } ]
    })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## An arc\n\nWhat it did.\n")

      out, err, code = run_log("arc", "--from-file", path,
                               env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

      assert_equal 0, code, err
      create = stub.requests.find { |r| r.method == "POST" && r.path.include?("/task/p1") }
      assert_equal "no-priority", create.json["priority"]
      assert_equal "An arc", create.json["title"]
      label = stub.requests.find { |r| r.method == "POST" && r.path.include?("/label") }
      assert_equal "arc", label.json["name"]
      assert_equal "t9", label.json["taskId"]
      assert_match(/#194/, out)
    end
  ensure
    stub&.shutdown
  end

  test "a task created but left unlabelled is reported, never reported as success" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "POST /task/p1" => [ 201, { "id" => "t9", "number" => 194, "title" => "An arc", "status" => "Open" } ],
      "POST /label" => [ 500, { "message" => "boom" } ]
    })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## An arc\n\nWhat it did.\n")

      _out, err, code = run_log("arc", "--from-file", path,
                                env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

      refute_equal 0, code
      assert_match(/#194 was created/, err)
      assert_match(/label/, err)
    end
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify both fail**

Run: `bin/rails test test/log_cli_test.rb -n "/creating an arc|left unlabelled/"`
Expected: FAIL.

- [ ] **Step 3: Replace `create_issue`**

```ruby
  # TWO CALLS, AND THE SECOND ONE CAN FAIL ON ITS OWN. POST /task/:projectId has no labels field, so
  # creation is not atomic the way Forgejo's single POST was: the task can exist with no label. That
  # is reported and never swallowed — an arc with no `arc` label is invisible to every search that
  # filters by kind, and silently so.
  #
  # THE PAYLOAD IS BUILT BEFORE ANY WIRE CALL, and that ordering is load-bearing exactly as it was
  # under Forgejo: project_id resolution makes a GET the first call of every write verb, and if the
  # payload were built afterwards it would still be nil when that GET failed — so the rescue would
  # report "nothing to file" for what is unambiguously a write.
  def create_task(title, body:, labels:, closed: false)
    payload = {
      title: title,
      description: body,
      priority: "no-priority",
      status: closed ? "Done" : "Open"
    }
    task = parse(api(:post, "/api/task/#{project_id}", payload), "/api/task")

    labels.each do |name|
      api(:post, "/api/label", { name: name, color: "#666666",
                                 workspaceId: workspace_id, taskId: task.fetch("id") })
    rescue Unreachable => e
      # NAMES THE TASK THAT DID GET CREATED. Re-raising bare would spool the create payload and
      # invite a second create on retry — a duplicate arc at a new number, which no citation points
      # at and nothing would flag.
      raise Unreachable, "##{task['number']} was created but the #{name.inspect} label failed: #{e.message}"
    end

    task
  rescue Unreachable => e
    raise Unreachable.new(e.message, payload: e.payload || payload, path: e.path || "/api/task")
  end
```

- [ ] **Step 4: Point the three write verbs at `create_task`**

`workspace_id` already exists — Task 11 defined it off the memoized `project` record, precisely so
`POST /label` does not need a second lookup or a second env var. Nothing to add here.

Update the three callers to use `create_task`: `arc` (label `arc`), `open_item` (label
`open-work`), `deploy` (label `deploy`). Their bodies are otherwise unchanged.

- [ ] **Step 5: Rewrite `setup`**

```ruby
  # IDEMPOTENT BY ASKING WHAT EXISTS, NOT BY TOLERATING A REFUSAL — the rule survives the move
  # unchanged. Forgejo allowed duplicate label names and a second run left 22 of 11; nothing
  # observed says Kaneo refuses them either, so `setup` still asks first and VERIFIES afterwards.
  # "I sent eleven requests" is not the claim this command makes; "eleven labels exist" is.
  def label_index
    @label_index ||= begin
      path = "/api/label/workspace/#{workspace_id}"
      body = parse(api(:get, path), path)
      list = body.is_a?(Array) ? body : body.fetch("labels", [])
      list.to_h { |l| [ l["name"], l["id"] ] }
    end
  end

  def setup
    already = LABELS & label_index.keys

    (LABELS - already).each do |name|
      api(:post, "/api/label", { name: name, color: "#666666", workspaceId: workspace_id })
    end

    @label_index = nil
    missing = LABELS - label_index.keys
    raise Unreachable, "labels missing after setup: #{missing.join(', ')}" if missing.any?

    puts "bin/log: #{LABELS.size} labels present (#{LABELS.size - already.size} created, #{already.size} already there)."
    EXIT_OK
  end
```

- [ ] **Step 6: Run the write-verb tests**

Run: `bin/rails test test/log_cli_test.rb -n "/creating an arc|left unlabelled|setup|deploy|open/"`
Expected: PASS.

- [ ] **Step 7: Mutation-check the unlabelled report**

Change the `rescue Unreachable` inside the label loop to `nil` (swallow it) and re-run.
Expected: "a task created but left unlabelled" goes RED. Restore.

- [ ] **Step 8: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "Create tasks and attach labels; an unlabelled task is reported, not swallowed"
```

---

### Task 15: `note` and `close`

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  test "note posts a comment against the resolved task id and never rewrites the description" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, [ { "id" => "abc", "number" => 178, "title" => "x", "status" => "Done" } ] ],
      "POST /comment" => [ 201, { "id" => "c1" } ]
    })
    out, err, code = run_log("note", "178", "a correction",
                             env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    comment = stub.requests.find { |r| r.method == "POST" }
    assert_equal "/api/comment/abc", comment.path
    assert_equal "a correction", comment.json["content"]
    refute stub.requests.any? { |r| r.method == "PUT" && r.path.include?("description") }
  ensure
    stub&.shutdown
  end

  test "close moves the task to Done and reports an already-closed one instead of re-sending" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, [
        { "id" => "a", "number" => 10, "title" => "open one", "status" => "Open" },
        { "id" => "b", "number" => 11, "title" => "done one", "status" => "Done" }
      ] ],
      "PUT /task/status" => [ 200, { "id" => "a", "status" => "Done" } ]
    })
    out, err, code = run_log("close", "10", "11", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    puts_sent = stub.requests.select { |r| r.method == "PUT" }
    assert_equal 1, puts_sent.size, "only the open one should be written"
    assert_equal "/api/task/status/a", puts_sent.first.path
    assert_match(/closed #10/, out)
    assert_match(/#11 was already closed/, out)
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify both fail**

Run: `bin/rails test test/log_cli_test.rb -n "/note posts a comment|close moves the task/"`
Expected: FAIL.

- [ ] **Step 3: Implement both**

```ruby
  # A CORRECTION IS A COMMENT, NOT AN EDIT — never rewrite the task description. Unchanged in intent
  # from the Forgejo version; only the endpoint and the payload key moved (`body` became `content`).
  def note(argv)
    number = issue_number!(argv.shift or raise UsageError, "note needs an issue number")
    text = argv.shift or raise UsageError, "note needs text"
    task = task_for(number)
    api(:post, "/api/comment/#{task.fetch('id')}", { content: text })

    puts "noted on ##{number}"
    EXIT_OK
  end

  CLOSED_STATUS = "Done"

  # CLOSING IS A COLUMN MOVE NOW, not a state change — Kaneo has no open/closed flag, only the board
  # column. Everything else about this verb survives the move: several numbers in one call because
  # the unit of work is "this branch is done"; each its own request, so a failure part way through
  # leaves the earlier ones closed and says which; and already-closed REPORTED rather than re-sent,
  # because a redundant write is silently idempotent and reads as "I closed it" for something
  # somebody else closed for a different reason.
  def close(argv)
    numbers = argv.map { |a| issue_number!(a) }
    raise UsageError, "close needs at least one issue number" if numbers.empty?

    numbers.each do |number|
      task = task_for(number)

      if task["status"] == CLOSED_STATUS
        puts "##{number} was already closed"
        next
      end

      api(:put, "/api/task/status/#{task.fetch('id')}", { status: CLOSED_STATUS })
      puts "closed ##{number} #{task['title']}"
    end
    EXIT_OK
  end
```

**`CLOSED_STATUS` must be a column the board actually has** — set it to whatever Task 5 step 3
recorded, not to `"Done"` on faith.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/log_cli_test.rb -n "/note posts a comment|close moves the task/"`
Expected: PASS.

- [ ] **Step 5: Mutation-check the already-closed guard**

Delete the `if task["status"] == CLOSED_STATUS` branch and re-run.
Expected: the close test goes RED on `assert_equal 1, puts_sent.size`. Restore.

- [ ] **Step 6: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "note comments, close moves the column; already-closed still reported not re-sent"
```

---

### Task 16: Usage text, env names, and the whole suite

**Files:**
- Modify: `bin/log:449-459`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Update the usage text**

```ruby
    ([ "bin/log — record work in Kaneo. The single write door.", "" ] + rows + [
      "",
      "Env: KANEO_URL (default http://kaneo.home), KANEO_WORKSPACE and KANEO_PROJECT " \
      "(both default tinkerex), " \
      "LOG_SPOOL_DIR (default tmp/log-pending), LOG_BRANCH"
    ]).join("\n")
```

- [ ] **Step 2: Update the two remaining user-facing strings**

`main`'s rescue says "Forgejo is unreachable"; `status` says "these are NOT in Forgejo". Both become
Kaneo.

- [ ] **Step 3: Run the whole file**

Run: `bin/rails test test/log_cli_test.rb`
Expected: all 44+ tests PASS. Fix any stragglers — most will be assertions naming Forgejo paths.

- [ ] **Step 4: Confirm no Forgejo name survives in the tool or its tests**

```bash
grep -ric "forgejo" bin/log test/log_cli_test.rb test/support/stub_kaneo.rb
```

Expected: `bin/log:0`, `test/log_cli_test.rb:0`, `test/support/stub_kaneo.rb:0`. A non-zero count in
`bin/log` is a live code path still pointing at a server that is about to be switched off.

- [ ] **Step 5: Smoke-test against the real instance**

The stub models nothing, so a green suite is not evidence the wire is right — this is the step that
closes that gap:

```bash
bin/log search "staging panel" && bin/log show 178 && bin/log status
```

Expected: real results from Kaneo, `#178` printing the staging-panel arc, and `status` reporting
nothing unfiled. **If `show 178` prints the wrong arc, the import is wrong** — stop and re-verify
Task 9 before going further.

- [ ] **Step 6: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log names Kaneo throughout; suite green and smoke-tested live"
```

---

# Phase E — Documentation

### Task 17: CLAUDE.md, commands, and the CI mentions

**Files:**
- Modify: `CLAUDE.md:9, 297, 318, 373-374, 430, 501, 565, 860, 1278, 1322`
- Modify: `.claude/commands/{deploy,execute-plan,finish-branch}.md`
- Modify: `config/ci.rb:111`, `test/docs_hygiene_test.rb:98`

**CLAUDE.md is 1,355 lines and `MAX_LINES` is 1,355.** Every edit here must be line-neutral. A
reflowed paragraph that gains one line fails `bin/ci`.

- [ ] **Step 1: Rewrite §11's opening, which is the one place the instance is named**

```markdown
**The canonical record is the self-hosted Kaneo at `http://kaneo.home`, project `tinkerex`**
```

The rest of §11 stands: issue numbers were preserved, so "110 arcs, `tinkerex#6`–`#115`" and the
`docs/STATUS.md` history are still true. **This line is the entire payoff of the number-preserving
import** — everything else that cites the record cites `tinkerex#N`, which did not move.

- [ ] **Step 2: Update §13's cheatsheet block (lines 373-374)**

```
# RECORDING WORK -- bin/log is the SINGLE write door onto the Kaneo at kaneo.home. MCP may READ
# it and never writes. Token via bin/secret (op://tinkerex/kaneo key/credential); never `export`.
```

**The vault reference must match `bin/log`'s `TOKEN_REF` exactly.** These disagreed under Forgejo —
the doc said `op://tinkerex/Forgejo/token`, the code read `op://tinkerex/forgejo key/credential` —
and §15's "verify a commit reference the way you verify a guard" applies to a vault path too.

- [ ] **Step 3: Update §15's close-out rule (line 1278)**

The sentence "the PRs are on GitHub, the record is a self-hosted Forgejo, nothing bridges them"
becomes "...a self-hosted Kaneo...". The argument is unchanged and still true.

- [ ] **Step 4: Update the remaining prose mentions**

Lines 9, 318, 430, 501, 565, 860, 1322 — each reads "the Forgejo record" or "in Forgejo". Replace
with "the record" or "in Kaneo" as the sentence requires, keeping every line's length close enough
not to reflow.

- [ ] **Step 5: Update the three commands and two test/config mentions**

```bash
grep -rn -i forgejo .claude/commands/ config/ci.rb test/docs_hygiene_test.rb
```

Fix each. `test/docs_hygiene_test.rb:98` is a failure *message* ("The record lives in Forgejo now") —
it is user-facing text and must be right.

- [ ] **Step 6: Verify the line count did not move**

```bash
wc -l CLAUDE.md
```

Expected: `1355`. If it grew, tighten the edits — do not raise `MAX_LINES`. That file's own header
forbids banking headroom for an unrelated change, and this arc is unrelated to why the ceiling exists.

- [ ] **Step 7: Run the docs gate**

Run: `bin/rails test test/docs_hygiene_test.rb test/ci_hygiene_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md .claude/commands config/ci.rb test/docs_hygiene_test.rb
git commit -m "The record lives in Kaneo: CLAUDE.md §11, §13, §15 and the commands"
```

---

### Task 18: Stop naming the product in code comments

**Files:**
- Modify: `app/models/maker/inventory_item.rb:55`
- Modify: `app/models/concerns/maker/text_only_rich_text.rb:8`
- Modify: `app/services/maker/project_intake.rb:73`
- Modify: `app/services/maker/previews/missing_backfill.rb:50`
- Modify: `app/services/maker/previews/enqueue.rb:51`
- Modify: `test/test_helper.rb:31`
- Modify: `test/ci_hygiene_test.rb:352`
- Modify: `test/integration/chunk_remote_journey_test.rb:25`
- Modify: `test/system/code_viewer_test.rb:54,202`
- Modify: `test/system/importer_test.rb:105`
- Modify: `test/services/maker/previews/missing_backfill_test.rb:177`

Thirteen comments say "the Forgejo record (CLAUDE.md §11)". §11's stated design is that code cites a
bare `tinkerex#N` **"so the instance can move without touching them"** — these named the product, so
they never got that protection. **Drop the name rather than swapping it**, and the next migration is
free.

- [ ] **Step 1: Rewrite them**

```bash
grep -rl "Forgejo record" app/ test/ | xargs sed -i '' 's/the Forgejo record/the record/g'
grep -rl "Forgejo's" app/ test/ | xargs sed -i '' "s/the Forgejo record's/the record's/g"
```

- [ ] **Step 2: Check what the sed left**

```bash
grep -rn -i forgejo app/ test/ lib/ config/ bin/ .claude/ CLAUDE.md
```

Expected: **no output.** Anything remaining is a sentence the sed could not fix mechanically — read
and rewrite it by hand.

- [ ] **Step 3: Confirm the history was left alone**

```bash
grep -rlc -i forgejo docs/superpowers/ | head
```

Expected: several files listed. **This is correct and must stay** — the dated specs and plans under
`docs/superpowers/` are records of finished work. They were true when written, and rewriting them
falsifies the history this repo is careful about.

- [ ] **Step 4: Run the full suite**

Run: `bin/ci test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/ test/
git commit -m "Code comments cite the record, not the product that happens to hold it"
```

---

# Phase F — Cut over

### Task 19: Full gates

- [ ] **Step 1: Run every gate**

Run: `bin/ci`
Expected: all seven gates green.

**Set `TINKEREX_SYNC_DIR`** if `test-chunk-remote` cannot find the sibling checkout — this is a
worktree, and that leg boots a real `chaim354/tinkerex-sync` host app.

- [ ] **Step 2: Compare the three backend legs**

`bin/ci` prints the run counts for `test` (share), `test-s3` and `test-chunk-remote` and **never
compares them** — that has always relied on a human reading them. Read them.

Expected: identical, or differing by the known ±2 assertions / ±1 skip flap recorded in
`tinkerex#131`. A structural difference means a test depends on the ambient `LIBRARY_BACKEND` and is
a real bug.

- [ ] **Step 3: Open the PR**

Per §15's close-out rule, this is standing authorization on a `claude/*` branch — commit, push, open
the PR without asking.

```bash
git push -u origin claude/forgejo-kaneo-migration-fec226
gh pr create --title "Move the canonical record from Forgejo to Kaneo" --body "$(cat <<'BODY'
186 issues, `tinkerex#6`–`#193`, moved from the self-hosted Forgejo to a self-hosted Kaneo with
every number preserved, so the 129 `tinkerex#N` citations in the tree keep resolving and only §11's
base URL moved.

Verified: `bin/ci` green; the three backend legs compared by hand; `bin/log show 178` smoke-tested
against the live instance; the import verified by read-back against the server rather than against
what was sent.

Not verified: nothing beyond the record was migrated — Forgejo holds no git data here, PRs are on
GitHub. Backup of Kaneo's Postgres is deliberately out of scope; the operator has a separate method.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

- [ ] **Step 4: File the arc as the PR opens, not afterwards**

```bash
bin/log arc --from-pr <n>
```

§15: the record is part of the work, filed as the PR opens. **This is the first real write through the
new door** — if it fails, that is the migration telling you something before anyone depends on it.

---

### Task 20: Retire Forgejo

> Only after Task 19's PR is merged and the export is archived off-box.

- [ ] **Step 1: Confirm the export is off-box**

Verify the archived copy of `tmp/forgejo-export.json` exists somewhere that is neither this Mac nor
the Unraid box, and that it opens.

- [ ] **Step 2: Stop the Forgejo container (human, browser)**

Stop it in Portainer. **Do not delete its volume yet** — a stopped container is reversible in seconds
and costs only disk.

- [ ] **Step 3: Confirm nothing still reaches for it**

```bash
grep -rn -i "forgejo" bin/ app/ lib/ config/ test/ .claude/ CLAUDE.md; echo "exit: $?"
```

Expected: no matches (`exit: 1` from grep finding nothing).

- [ ] **Step 4: Verify the record still answers**

```bash
bin/log show 178 && bin/log search "arc" | head -5 && bin/log status
```

Expected: all three work with Forgejo stopped. **This is the proof the migration is complete** — the
record answering while the old server is down.

- [ ] **Step 5: Remove the NPM proxy host for `forgejo.home` (human, browser)**

- [ ] **Step 6: Record the retirement**

```bash
bin/log open "Forgejo stopped; its volume is still on the box and can be removed after a settling period"
```

---

### Task 21: Remove the migration tooling

- [ ] **Step 1: Delete the one-time tool**

```bash
git rm bin/migrate-record
```

It talks to a server that no longer runs. Leaving it is dead code that reads as live, and the next
person to open it would be reading instructions for a machine that is off. Its history is in git and
the export file is archived; both survive the deletion.

- [ ] **Step 2: Run the gates**

Run: `bin/ci`
Expected: PASS — nothing references it.

- [ ] **Step 3: Commit and close the arc**

```bash
git commit -m "Remove the one-time migration tool; Forgejo is gone"
```

Then, at merge:

```bash
bin/log close <arc-number>
```

**An arc never closes itself** — the PRs are on GitHub, the record is on Kaneo, and nothing bridges
them.
