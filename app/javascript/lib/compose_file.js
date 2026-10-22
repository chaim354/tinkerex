// A VISITOR'S docker-compose.yml, BUILT IN THE BROWSER FROM THE REPO'S OWN FILE (2026-10-21; plan
// docs/superpowers/plans/2026-10-21-compose-generator.md). The page at /install/compose hands this
// module Tinkerex::ComposeTemplate's derivation of docker-compose.yml -- the parsed tree with its
// `${VAR:-default}` interpolations, the comments by path, the Tools set and the network-share example
// -- and the visitor's choices; it answers the finished file. Nothing here talks to the network: a
// password typed into the page reaches this function and the page's own preview, and nothing else.
//
// THE TEMPLATE IS NEVER COPIED HERE. Every service, setting and comment comes from the template, so
// a change to docker-compose.yml reaches the generated file with no edit in this module. What this
// module knows by hand is which variables the form sets, how a share replaces the library bind, how
// the SMB option list is spelled, and how to write YAML; test/system/compose_generator_test.rb
// compares its all-defaults output with the repo file, structure for structure.
//
// TWO ESCAPES, IN THIS ORDER, ON EVERY STRING. Compose interpolates `$` in every value, so a literal
// `$` is written `$$` first; then the string is written as a YAML scalar, plain only when nothing in
// it could be read as YAML syntax, otherwise double-quoted with JSON escapes, which YAML reads the
// same way. A comma in the SMB password is written `,,` before either, because the mount options are
// a comma-separated list (docs/INSTALL.md section 3).

// The values YAML 1.1 reads as booleans or null, which a plain scalar must never be (Psych and the
// Go parser compose uses disagree about some of them, so all are quoted).
const BOOL_OR_NULL = /^(?:y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF|null|Null|NULL|~)$/
// A plain scalar starts with a letter, `_` or `/` and holds nothing YAML could read as syntax: no
// space (so no `: ` and no ` #`), no quote, backslash, `$`, `#`, `=`, comma or bracket. Two narrow
// dot-first shapes are allowed, a path (`.:/library`, `./x`) and a bare name (`.env`), because no
// YAML number starts that way; `.inf` and `.nan` are refused below. A duration (`30s`) is the one
// digit-first shape; every other could be a number (`8080:80` is a base-60 integer in YAML 1.1).
const PLAIN = /^(?:[A-Za-z_/][A-Za-z0-9_./@+:-]*|\.[:/][A-Za-z0-9_./@+:-]*|\.[A-Za-z][A-Za-z0-9_]*|\d+(?:ms|s|m|h))$/
const FLOAT_WORD = /^\.(?:inf|Inf|INF|nan|NaN|NAN)$/
const KEY = /^[A-Za-z_][A-Za-z0-9_.-]*$/
// `${NAME}` and `${NAME:-default}` are the two spellings docker-compose.yml uses; `$$` is a literal
// dollar. Any other `$` is a spelling this module does not resolve, and it throws rather than guess.
const INTERPOLATION = /\$\$|\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$/g

const TAG = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/
const SMB_VERSIONS = ["3.0", "2.1"]
const AUTHENTICATIONS = ["plain", "login", "cram_md5"]

function isMap(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// JSON's string syntax is YAML's double-quoted syntax for everything JSON.stringify emits; the line
// and paragraph separators, the C1 controls, DEL and the byte-order mark are escaped as well, because
// YAML 1.1 counts the first two as line breaks and the rest as unprintable.
export function quote(text) {
  return JSON.stringify(text).replace(/[\u007f-\u009f\u2028\u2029\ufeff]/g,
    (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`)
}

// Compose reads every `$` as the start of a variable; `$$` is its literal dollar.
function composeEscape(text) {
  return text.replaceAll("$", () => "$$")
}

export function scalar(value) {
  if (value === null || value === undefined) return "null"
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  const text = composeEscape(String(value))
  return PLAIN.test(text) && !BOOL_OR_NULL.test(text) && !FLOAT_WORD.test(text) && !text.endsWith(":") ? text : quote(text)
}

function flowScalar(value) {
  return typeof value === "string" ? quote(composeEscape(value)) : scalar(value)
}

function yamlKey(key) {
  const text = String(key)
  return KEY.test(text) && !BOOL_OR_NULL.test(text) ? text : quote(text)
}

function isPort(value) {
  return /^\d{1,5}$/.test(value) && Number(value) >= 1 && Number(value) <= 65535
}

function isId(value) {
  return /^\d{1,10}$/.test(value) && Number(value) <= 2147483647
}

// A colon is Docker's separator between the host path and the container path, so a host path may
// hold one only as a Windows drive letter's (C:\ or C:/).
function hostPathColonOk(path) {
  return !path.replace(/^[A-Za-z]:(?=[\\/])/, "").includes(":")
}

// THE FORM'S RULES, as messages keyed by input name. An empty object means the file can be built.
export function validate(c) {
  const errors = {}
  const need = (field, ok, message) => { if (!ok && !errors[field]) errors[field] = message }

  for (const [field, value] of Object.entries(c)) {
    need(field, typeof value !== "string" || value.isWellFormed(), "This holds a character that cannot be written to a file. Retype it.")
  }
  need("port", isPort(c.port), "A port is a whole number from 1 to 65535.")
  need("puid", c.puid === "" || isId(c.puid), "A user id is a whole number, such as 1000 (id -u prints yours).")
  need("pgid", c.pgid === "" || isId(c.pgid), "A group id is a whole number, such as 1000 (id -g prints yours).")
  need("tag", TAG.test(c.tag), "A tag is letters, digits, dots, dashes and underscores, such as latest.")

  if (c.library === "share") {
    need("shareServer", c.shareServer !== "", "The computer that shares the folder: its name or IP address, such as 192.168.1.50.")
    need("shareServer", !/[/\\\s,]/.test(c.shareServer), "Only the server's name or address, with no slashes, spaces or commas.")
    need("shareName", c.shareName !== "", "The share's name, such as Files.")
    need("shareName", !c.shareName.includes("\\"), "Write a folder inside the share with / rather than \\.")
    need("shareName", !c.shareName.startsWith("/"), "Only the share's name, such as Files; the server comes from the field above.")
    if (!c.shareGuest) {
      need("shareUser", c.shareUser !== "", "The user name the share accepts, or tick Guest.")
      need("shareUser", !c.shareUser.includes(","), "A comma would end the user name in the mount options.")
    }
    need("shareVersion", SMB_VERSIONS.includes(c.shareVersion), "Choose 3.0 or 2.1.")
  } else {
    need("folderPath", hostPathColonOk(c.folderPath), "A colon can only follow a Windows drive letter (C:\\). Docker reads any other colon as the end of the path.")
  }

  const mail = c.smtpAddress !== ""
  need("smtpAddress", mail || !(c.smtpUser || c.smtpPassword || c.smtpDomain || c.mailFrom),
    "Mail is off until the SMTP server is set. Set it, or clear the other mail fields.")
  need("appHost", !mail || c.appHost !== "", "Required with an SMTP server: the links in mail point at it.")
  need("appHost", !/[\s/]/.test(c.appHost), "Only the host name or address, such as maker.example.net, with no https:// or path.")
  need("smtpPort", !mail || isPort(c.smtpPort), "A port is a whole number from 1 to 65535.")
  need("smtpAuthentication", AUTHENTICATIONS.includes(c.smtpAuthentication), "Choose plain, login or cram_md5.")
  return errors
}

function device(c) {
  return `//${c.shareServer}/${c.shareName}`
}

// THE SMB OPTION LIST, IN THE EXAMPLE'S OWN ORDER. Each option the example carries is kept, and the
// five the form sets are replaced: `guest` takes the place of the user name and password, a comma in
// the password is doubled, and uid/gid follow PUID/PGID -- they make the share's files belong to the
// user the app runs as (INSTALL.md section 3), so the two must agree.
function mountOptions(example, c) {
  const seen = new Set()
  const out = []
  for (const option of example.split(",")) {
    const [name, value] = option.split(/=(.*)/s)
    seen.add(name)
    if (name === "username") out.push(c.shareGuest ? "guest" : `username=${c.shareUser}`)
    else if (name === "password") { if (!c.shareGuest) out.push(`password=${c.sharePassword.replaceAll(",", ",,")}`) }
    else if (name === "vers") out.push(`vers=${c.shareVersion}`)
    else if (name === "uid") out.push(`uid=${c.puid || value}`)
    else if (name === "gid") out.push(`gid=${c.pgid || value}`)
    else out.push(option)
  }
  for (const name of ["username", "password", "vers", "uid", "gid"]) {
    if (!seen.has(name)) throw new Error(`the network-share example's options have no ${name}=`)
  }
  return out.join(",")
}

function driverOpts(example, c) {
  const opts = {}
  for (const [name, value] of Object.entries(example)) {
    if (name === "device") opts[name] = device(c)
    else if (name === "o") opts[name] = mountOptions(value, c)
    else opts[name] = value
  }
  return opts
}

// What the form sets, by the variable docker-compose.yml interpolates. `undefined` means the file's
// own default. The app image keeps its repository and takes the tag.
function lookup(c) {
  return (name, fallback) => {
    switch (name) {
      case "TINKEREX_PORT": return c.port
      case "PUID": return c.puid
      case "PGID": return c.pgid
      case "LIBRARY_HOST_PATH": return c.library === "share" ? device(c) : c.folderPath
      case "TINKEREX_IMAGE": {
        if (!/:[^:/]+$/.test(fallback ?? "")) throw new Error("TINKEREX_IMAGE's default names no tag to replace")
        return fallback.replace(/:[^:/]+$/, `:${c.tag}`)
      }
      default: return undefined
    }
  }
}

function resolve(text, find) {
  return text.replace(INTERPOLATION, (match, name, fallback) => {
    if (match === "$$") return "$"
    if (match === "$") throw new Error(`docker-compose.yml holds a $ this page cannot resolve: ${text}`)
    const value = find(name, fallback)
    return value !== undefined && value !== "" ? value : (fallback ?? "")
  })
}

function resolveTree(node, find) {
  if (typeof node === "string") return resolve(node, find)
  if (Array.isArray(node)) return node.map((item) => resolveTree(item, find))
  if (isMap(node)) return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, resolveTree(v, find)]))
  return node
}

function dropComments(comments, prefix) {
  for (const key of Object.keys(comments)) {
    if (key === prefix || key.startsWith(`${prefix}/`)) delete comments[key]
  }
}

// THE ACCOUNTS-AND-MAIL LINES (docs/INSTALL.md section 4) and FORCE_SSL, which .env.example lists
// beside them. None is in docker-compose.yml, where they come from .env; a generated file inlines
// them, each group under a comment of its own.
function extraEnvironment(c) {
  const lines = []
  if (c.forceSsl) {
    lines.push(["FORCE_SSL", "1", [
      "# Reached over HTTPS through a reverse proxy: plain HTTP redirects, cookies are secure and",
      "# links in mail say https. Without TLS in front this locks you out."
    ]])
  }
  if (c.smtpAddress) {
    lines.push(["SMTP_ADDRESS", c.smtpAddress, [
      "# Mail: account confirmation and password reset (docs/INSTALL.md section 4). APP_HOST is the",
      "# name or address people reach this server at, which the links in mail point to."
    ]])
    lines.push(["APP_HOST", c.appHost])
    lines.push(["SMTP_PORT", c.smtpPort])
    if (c.smtpUser) {
      lines.push(["SMTP_USER_NAME", c.smtpUser])
      lines.push(["SMTP_PASSWORD", c.smtpPassword])
      lines.push(["SMTP_AUTHENTICATION", c.smtpAuthentication])
    }
    if (c.smtpDomain) lines.push(["SMTP_DOMAIN", c.smtpDomain])
    if (!c.smtpStarttls) lines.push(["SMTP_STARTTLS", "false"])
    if (c.mailFrom) lines.push(["MAIL_FROM", c.mailFrom])
  } else if (c.appHost) {
    lines.push(["APP_HOST", c.appHost, ["# The name or address people reach this server at (docs/INSTALL.md section 4)."]])
  }
  return lines
}

// A typed value shown inside a comment: one line, whatever was pasted.
function inComment(text) {
  return text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
}

function header(c, { source, guide }) {
  const lines = [
    `# Tinkerex${c.tools ? " with the Tools gallery" : ""}${source ? `, made at ${inComment(source)}` : ""}.`,
    "# In the folder this file is in:",
    "#",
    `#   docker compose up -d                           pull and start; then http://localhost:${c.port}`,
    "#   docker compose pull && docker compose up -d    update",
    "#"
  ]
  if (c.library === "share") {
    lines.push(`# The library is the network share ${inComment(device(c))}. Docker connects to it as the app`)
    lines.push("# starts, so the share must be reachable then.")
  } else if (c.folderPath) {
    lines.push(`# The library is ${inComment(c.folderPath)}, with a .trash/ inside it.`)
  } else {
    lines.push("# The library is the folder this file is in, with a .trash/ inside it, so not Downloads.")
  }
  const password = (c.library === "share" && !c.shareGuest && c.sharePassword) || (c.smtpAddress && c.smtpUser && c.smtpPassword)
  if (password) lines.push("# It holds a password in plain text: keep it to yourself (chmod 600 docker-compose.yml).")
  if (guide) lines.push(`# Every setting is explained in ${inComment(guide)}`)
  return lines
}

// BLOCK YAML, two spaces a level and sequences indented under their key, the shape docker-compose.yml
// is written in. A comment is printed at the indentation of the node it leads, or of the children of
// the block it closes; a blank line separates the top-level keys and comes before a service that has
// a comment of its own.
function emit(tree, leading, trailing, flow) {
  const out = []
  const put = (indent, text) => out.push(" ".repeat(indent) + text)
  const comments = (key, indent) => { for (const line of leading[key] || []) put(indent, line) }
  const closing = (key, indent) => { for (const line of trailing[key] || []) put(indent, line) }

  function entry(path, key, value, indent) {
    const at = path.join("/")
    comments(at, indent)
    const name = yamlKey(key)
    if (isMap(value)) {
      const keys = Object.keys(value)
      if (keys.length === 0 && !trailing[at]) return put(indent, `${name}: {}`)
      put(indent, `${name}:`)
      keys.forEach((child, i) => {
        if (at === "services" && i > 0 && leading[`${at}/${child}`]) out.push("")
        entry([...path, child], child, value[child], indent + 2)
      })
      return closing(at, indent + 2)
    }
    if (Array.isArray(value)) {
      if (flow.has(at)) return put(indent, `${name}: [${value.map(flowScalar).join(", ")}]`)
      if (value.length === 0 && !trailing[at]) return put(indent, `${name}: []`)
      put(indent, `${name}:`)
      value.forEach((item, i) => listItem([...path, i], item, indent + 2))
      return closing(at, indent + 2)
    }
    put(indent, value === null ? `${name}:` : `${name}: ${scalar(value)}`)
  }

  function listItem(path, item, indent) {
    const at = path.join("/")
    comments(at, indent)
    if (Array.isArray(item)) throw new Error(`${at}: a list inside a list`)
    if (!isMap(item)) return put(indent, `- ${scalar(item)}`)
    const [first, ...rest] = Object.keys(item)
    if (first === undefined) return put(indent, "- {}")
    if (isMap(item[first]) || Array.isArray(item[first])) throw new Error(`${at}: a list item opening with a block`)
    put(indent, `- ${yamlKey(first)}: ${scalar(item[first])}`)
    rest.forEach((child) => entry([...path, child], child, item[child], indent + 2))
    closing(at, indent + 2)
  }

  Object.keys(tree).forEach((key, i) => {
    if (i > 0) out.push("")
    entry([key], key, tree[key], 0)
  })
  return out
}

// THE FILE. `template` is Tinkerex::ComposeTemplate#to_h; `c` the choices (validate them first);
// `source` the page's address and `guide` INSTALL.md's, both for the header. Throws when the template
// no longer has the shape this module edits, which the system test turns into a red build.
export function generate(template, c, { source = "", guide = "" } = {}) {
  const { share, tools } = template
  const tree = resolveTree(structuredClone(template.tree), lookup(c))
  const leading = { ...template.leading }
  const trailing = { ...template.trailing }
  const app = tree.services?.[share.service]
  if (!isMap(app) || !isMap(app.environment) || !Array.isArray(app.volumes)) {
    throw new Error(`the ${share.service} service has no environment mapping or volume list`)
  }
  tree.volumes ??= {}

  if (!c.tools) {
    for (const name of tools.services) {
      delete tree.services[name]
      dropComments(leading, `services/${name}`)
      dropComments(trailing, `services/${name}`)
    }
    for (const key of tools.env) {
      delete app.environment[key]
      dropComments(leading, `services/${share.service}/environment/${key}`)
    }
    for (const name of tools.volumes) {
      delete tree.volumes[name]
      dropComments(leading, `volumes/${name}`)
    }
  }

  if (c.library === "share") {
    app.volumes[share.bind] = `${share.volume}:${share.target}`
    delete trailing[`services/${share.service}/volumes`]
    delete trailing.volumes
    tree.volumes[share.volume] = { driver_opts: driverOpts(share.example.driver_opts, c) }
    leading[`volumes/${share.volume}`] = share.note
  }

  for (const [key, value, comments] of extraEnvironment(c)) {
    app.environment[key] = value
    if (comments) leading[`services/${share.service}/environment/${key}`] = comments
  }

  return [...header(c, { source, guide }), "", ...emit(tree, leading, trailing, new Set(template.flow))].join("\n") + "\n"
}
