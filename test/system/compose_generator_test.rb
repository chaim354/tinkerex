require "application_system_test_case"
require "yaml"

# THE COMPOSE GENERATOR IN A BROWSER (/install/compose, 2026-10-21; plan
# docs/superpowers/plans/2026-10-21-compose-generator.md). The file is built by
# app/javascript/lib/compose_file.js, so only a browser can say what it builds -- that is this tier's
# rule (README.md), and every assertion about the file reads it from the page's own preview or from
# the module the page loaded, then parses it with Psych.
#
# THE DRIFT GUARD IS THE FIRST TEST. The generator builds from docker-compose.yml itself
# (Tinkerex::ComposeTemplate), and with every input at its default its output must parse to exactly
# the repo file with each `${VAR:-default}` resolved, and carry exactly the repo file's comments
# (less the header it replaces and the `bin/rails generate sidecar` markers). A change to the compose
# file therefore either flows through or fails here; it never drifts quietly.
#
# "PARSES BACK TO EXACTLY THE TYPED VALUE" MEANS AFTER COMPOSE HAS READ IT: Psych reads the YAML, then
# `$$` becomes `$` (compose's interpolation; a lone `$` would be a variable and fails the test), and
# for the SMB options `,,` becomes `,`. `literal` and `mount_options` below are those two readers.
#
# MUTATION-CHECKED (§15), each run red and restored:
#   1. compose_file.js `resolve` returning "" for an unset variable instead of its default: the drift
#      test goes red (image, port and the library bind lose their defaults).
#   2. `emit` printing no leading comments: the drift test's comment comparison goes red.
#   3. `composeEscape` returning its input: the matrix goes red on every `$` case ("lone $").
#   4. `quote` no longer escaping DEL and the C1 controls: the matrix goes red on the password holding
#      NEL and DEL ("control characters are not allowed"). Leaving U+2028 raw instead stays GREEN:
#      Psych keeps it inside double quotes, so that escape is for an editor's sake, not the parser's.
#   5. `isPort` answering true: the validation test goes red (port 0 builds a file).
#   6. compose_controller.js `update` calling fetch("/up?" + port): the no-network test goes red.
#   7. pages/public.css's phone rule `.compose-layout` back to `1fr` without minmax: the 375px test
#      goes red (the YAML's longest line widens the page).
#   8. BOOL_OR_NULL without its `i` flag: the matrix goes red on `oN`, which Psych reads as true.
#   9. The mount-flag refusal, the bare-folder refusal and the U+FFFE/U+FFFF refusal, each answering
#      true: the validation test goes red at its own assertion.
class ComposeGeneratorSystemTest < ApplicationSystemTestCase
  REPO_FILE = Rails.root.join("docker-compose.yml")
  # The form's own defaults, as lib/compose_file.js receives them from compose_controller.js.
  DEFAULTS = {
    library: "folder", folderPath: "", shareServer: "", shareName: "", shareGuest: false, shareUser: "",
    sharePassword: "", shareVersion: "3.0", puid: "", pgid: "", port: "8080", tag: "latest", tools: true,
    forceSsl: false, smtpAddress: "", appHost: "", smtpPort: "587", smtpUser: "", smtpPassword: "",
    smtpAuthentication: "plain", smtpStarttls: true, smtpDomain: "", mailFrom: ""
  }.freeze
  TOOLS = (Tinkerex::Sidecars.new.names + %w[addons]).freeze

  setup do
    @root = use_fresh_share_library!
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # ---- readers ------------------------------------------------------------------------------------

  def preview = page.evaluate_script("document.querySelector('.compose-preview').textContent")

  # Compose's reading of a parsed value: `$$` is a literal dollar, a lone `$` a variable.
  def literal(node)
    case node
    when String then node.gsub(/\$\$|\$/) { |m| m == "$$" ? "$" : flunk("a lone $ compose would interpolate: #{node.inspect}") }
    when Array then node.map { literal(_1) }
    when Hash then node.transform_values { literal(_1) }
    else node
    end
  end

  def parse(yaml) = literal(YAML.safe_load(yaml))

  # docker-compose.yml as compose runs it with nothing set: every `${VAR:-default}` is its default.
  def repo_resolved
    resolve = lambda do |node|
      case node
      when String then node.gsub(/\$\$|\$\{[A-Za-z_][A-Za-z0-9_]*(?::-([^}]*))?\}/) { |m| m == "$$" ? "$" : ($1 || "") }
      when Array then node.map { resolve.(_1) }
      when Hash then node.transform_values { resolve.(_1) }
      else node
      end
    end
    resolve.(YAML.safe_load(REPO_FILE.read))
  end

  def comments(text) = text.lines.map(&:strip).select { _1.start_with?("#") }

  # The SMB option list as the kernel reads it: `,,` is a comma, a single `,` ends an option.
  def mount_options(o)
    opts = [ +"" ]
    i = 0
    while i < o.size
      if o[i] == "," && o[i + 1] == ","
        opts.last << ","
        i += 2
      elsif o[i] == ","
        opts << +""
        i += 1
      else
        opts.last << o[i]
        i += 1
      end
    end
    opts
  end

  # The commented example at the end of the repo file, uncommented: the share block the generator
  # must write when given the example's own values.
  def repo_share_example
    lines = REPO_FILE.read.lines.drop_while { |l| !l.match?(/\A\s*# library:\s*\z/) }
    YAML.safe_load(lines.map { _1.sub(/\A\s*# ?/, "") }.join).fetch("library")
  end

  # Runs lib/compose_file.js -- the module the page loaded -- over each set of choices, with the
  # template the page carries. Returns [{ "yaml" =>, "errors" => }] or raises the module's error.
  def build(*choices)
    results = page.evaluate_async_script(<<~JS, choices.map { DEFAULTS.merge(_1) }.to_json)
      const json = arguments[0], done = arguments[arguments.length - 1];
      import("lib/compose_file").then((m) => {
        const root = document.querySelector("[data-controller~=compose]");
        const template = JSON.parse(root.dataset.composeTemplateValue);
        const options = { source: location.origin + location.pathname, guide: root.dataset.composeGuideValue };
        done(JSON.parse(json).map((c) => {
          try { return { yaml: m.generate(template, c, options), errors: m.validate(c) } }
          catch (e) { return { error: String(e) } }
        }));
      }).catch((e) => done([{ error: String(e) }]));
    JS
    results.each { |r| raise r["error"] if r["error"] }
    results
  end

  def open_page
    visit public_compose_path
    assert_selector ".compose-preview", text: "services:"
  end

  # ---- the drift guard ----------------------------------------------------------------------------

  test "with every input at its default the file is the repo's docker-compose.yml, structure and comments" do
    open_page
    yaml = preview
    assert_equal repo_resolved, parse(yaml), "the generated file no longer matches docker-compose.yml"

    header, body = yaml.split(/^services:$/, 2)
    assert body, "the file has no services: line"
    repo = REPO_FILE.read
    repo_header = repo[/\A(?:#.*\n)+/]
    markers = Tinkerex::Sidecars::MARKERS.values.filter_map { |file, text| text if file == :compose }
    expected = comments(repo) - comments(repo_header) - markers
    assert_equal expected.sort, comments(body).sort, "the file's comments are not the repo file's"
    assert_includes header, "made at #{current_url.split('?').first}"
    assert_includes header, "docker compose up -d"
    assert_equal yaml, build({}).first["yaml"], "the page's own preview is not what the module builds from the form's defaults"
  end

  test "without the Tools gallery the file loses exactly the three Tools services, their URLs and their volume" do
    open_page
    uncheck "The Tools gallery"
    assert_no_selector ".compose-preview", text: "boxes:"
    expected = repo_resolved
    TOOLS.each { expected["services"].delete(_1) }
    sidecars = Tinkerex::Sidecars.new
    (sidecars.names.map { sidecars.env_key(_1) } + %w[ADDON_SOURCE_URL]).each { expected.dig("services", "web", "environment").delete(_1) }
    expected["volumes"].delete("openscad_cache")
    yaml = preview
    assert_equal expected, parse(yaml)
    refute_match(/Tools gallery\.|wired to the three services/, yaml, "a Tools comment outlived the Tools")
  end

  test "a network share typed with the example's own values writes the example the repo file comments out" do
    open_page
    choose "A network share (SMB)"
    fill_in "compose-share-server", with: "192.168.1.50"
    fill_in "compose-share-name", with: "Files"
    fill_in "compose-share-user", with: "you"
    fill_in "compose-share-password", with: "your-password"
    assert_selector ".compose-preview", text: "driver_opts:"

    expected = repo_resolved
    expected.dig("services", "web", "volumes")[1] = "library:/library"
    expected.dig("services", "web", "environment")["LIBRARY_HOST_PATH"] = "//192.168.1.50/Files"
    expected["volumes"]["library"] = repo_share_example
    yaml = preview
    assert_equal expected, parse(yaml)
    refute_includes yaml, "# - library:/library", "the switch-to-a-share instructions outlived the switch"
    assert_includes yaml, "# The network share behind `library:/library` above."
  end

  # ---- escaping -----------------------------------------------------------------------------------

  # EVERY AWKWARD CHARACTER, THROUGH THE MODULE THE PAGE LOADED, PARSED BACK. One page visit, many
  # files. The values are what the page would hand the module after its own trim.
  test "paths, passwords and plain-looking strings parse back to exactly what was typed" do
    open_page
    paths = [
      "C:\\Users\\you\\My Workshop #1",
      "C:/Users/you/Work \"shop\" $HOME ${X} 'q' \\\\server",
      "/mnt/user/My Files #2/\u00fcber: a",
      "~/Workshop", "./relative path", "/tmp/a,b [c] {d} & * ! | > % @ `"
    ].reject { _1.sub(/\A[A-Za-z]:(?=[\\\/])/, "").include?(":") }
    folder_cases = paths.map { |path| { folderPath: path } }

    passwords = [
      "p@ss,w$rd \"q\" \\ x: #y {z} [a] 'b' $$ ${HOME} \u00fc",
      ",leading and trailing,", "a,,b", "line\u2028sep\u2029para\u0085nel\u007fdel\tab",
      "emoji \u{1F511} key", "", "=equals=", "#", "$"
    ]
    share_cases = passwords.map do |password|
      { library: "share", shareServer: "nas", shareName: "My Files", shareUser: "DOMAIN\\you name", sharePassword: password }
    end

    # Scalars YAML would read as something else if written plain.
    # Psych matches the boolean and null words without regard to case, so the mixed spellings too.
    plain_looking = %w[on off yes no true false null ~ oN yEs tRUE nO fALSE nuLL .iNf .nAn Y n
                       1e3 0777 0x1F 12:30 .inf .nan - ? & * ! % @ ` | > 8080:80 a: #x]
    mail_cases = plain_looking.map do |word|
      { smtpAddress: "smtp.example.net", appHost: "maker.example.net", smtpUser: "u@example.net",
        smtpPassword: "#{word} \"q\" $x \\", smtpDomain: word, mailFrom: "\"Tinkerex\" <#{word}@x>" }
    end

    cases = folder_cases + share_cases + mail_cases + [ { tag: "1.2.0", puid: "0", pgid: "2147483647", port: "65535" } ]
    results = build(*cases)
    assert_equal cases.size, results.size

    cases.zip(results).each do |choices, result|
      assert_empty result["errors"], "#{choices.inspect} should be valid"
      file = parse(result["yaml"])
      web = file.dig("services", "web")
      env = web["environment"]
      if (path = choices[:folderPath])
        assert_equal "#{path}:/library", web["volumes"][1], path.inspect
        assert_equal path, env["LIBRARY_HOST_PATH"], path.inspect
      elsif choices[:library] == "share"
        opts = mount_options(file.dig("volumes", "library", "driver_opts", "o"))
        assert_includes opts, "password=#{choices[:sharePassword]}", choices[:sharePassword].inspect
        assert_includes opts, "username=DOMAIN\\you name"
        assert_equal "//nas/My Files", file.dig("volumes", "library", "driver_opts", "device")
      elsif choices[:smtpDomain]
        assert_equal choices[:smtpDomain], env["SMTP_DOMAIN"], choices[:smtpDomain].inspect
        assert_equal choices[:smtpPassword], env["SMTP_PASSWORD"]
        assert_equal choices[:mailFrom], env["MAIL_FROM"]
        assert_equal "maker.example.net", env["APP_HOST"]
      else
        assert_equal "ghcr.io/chaim354/tinkerex:1.2.0", web["image"]
        assert_equal [ "65535:80" ], web["ports"]
        assert_equal [ "0", "2147483647" ], env.values_at("PUID", "PGID")
      end
    end
  end

  # THE FORM ITSELF, typed into: the controller's reading, trimming and wiring, which the module test
  # above cannot see. Passwords are taken as typed; a path loses only its outer spaces.
  test "values typed into the page reach the file exactly" do
    open_page
    fill_in "compose-folder-path", with: "  C:\\Users\\you\\Work $hop #1  "
    fill_in "compose-puid", with: "99"
    fill_in "compose-pgid", with: "100"
    fill_in "compose-port", with: "8443"
    assert_selector ".compose-preview", text: "8443:80"
    file = parse(preview)
    assert_equal "C:\\Users\\you\\Work $hop #1:/library", file.dig("services", "web", "volumes", 1)
    assert_equal %w[99 100], file.dig("services", "web", "environment").values_at("PUID", "PGID")
    assert_includes preview, "http://localhost:8443"

    choose "A network share (SMB)"
    fill_in "compose-share-server", with: "192.168.1.50"
    fill_in "compose-share-name", with: "Maker Files"
    fill_in "compose-share-user", with: "you"
    fill_in "compose-share-password", with: " p,a$s \"w\" #x "
    select "2.1: an older NAS", from: "compose-share-version"
    assert_selector ".compose-preview", text: "vers=2.1"
    opts = mount_options(parse(preview).dig("volumes", "library", "driver_opts", "o"))
    assert_equal [ "username=you", "password= p,a$s \"w\" #x ", "vers=2.1", "uid=99", "gid=100" ], opts.first(5)
    assert_includes preview, "It holds a password in plain text"

    check "A guest share, with no user name or password"
    assert_no_selector "#compose-share-user", visible: true
    assert_equal "guest", mount_options(parse(preview).dig("volumes", "library", "driver_opts", "o")).first
    assert_equal page.evaluate_script("document.querySelector('[data-controller~=compose]').dataset.copyTextValue"), preview,
                 "Copy would put something other than the preview on the clipboard"
  end

  # ---- validation ---------------------------------------------------------------------------------

  test "an invalid value names itself, and there is no file to download or copy until it is fixed" do
    open_page
    [
      [ "compose-port", "0", "A port is a whole number from 1 to 65535.", "Port" ],
      [ "compose-puid", "abc", "A user id is a whole number", "PUID" ],
      [ "compose-tag", "bad tag", "A tag is letters, digits, dots, dashes and underscores", "Image tag" ],
      [ "compose-folder-path", "/mnt/a:b", "A colon can only follow a Windows drive letter", "Folder" ],
      # A bare name is a named volume to compose, which refuses the file ("undefined volume").
      [ "compose-folder-path", "Workshop", "Start a folder beside this file with ./", "Folder" ]
    ].each do |id, value, message, label|
      original = find_field(id).value
      fill_in id, with: value
      assert_selector "##{id}-error", text: message
      assert_selector "##{id}[aria-invalid=true]"
      assert_button "Download", disabled: true
      assert_button "Copy", disabled: true
      assert_selector ".compose-status", exact_text: "Fix #{label} to see the file."
      assert_no_selector ".compose-preview", visible: true
      assert_equal "", page.evaluate_script("document.querySelector('[data-controller~=compose]').dataset.copyTextValue")
      fill_in id, with: original
      assert_no_selector "##{id}-error", visible: true
      assert_button "Download", disabled: false
    end

    choose "A network share (SMB)"
    assert_selector "#compose-share-server-error", text: "The computer that shares the folder"
    assert_selector "#compose-share-name-error", text: "The share's name"
    assert_selector "#compose-share-user-error", text: "or tick Guest"
    fill_in "compose-share-server", with: "//nas"
    assert_selector "#compose-share-server-error", text: "no slashes"
    # Docker lifts `ro` out of the option list before the kernel reads `,,` (moby's parseOptions).
    fill_in "compose-share-password", with: "abc,ro"
    assert_selector "#compose-share-password-error", text: "Docker reads \",ro\" in a password as a mount option"
    fill_in "compose-share-password", with: "abc,road"
    assert_no_selector "#compose-share-password-error", visible: true

    # What no input should hold: a lone surrogate, and the two characters YAML counts as unprintable.
    refused = build({ folderPath: "/a\uFFFFb" }, { smtpAddress: "s", appHost: "h", smtpPassword: "x\uFFFEy" }, { folderPath: "/ab" })
    assert_match(/cannot be written/, refused[0].dig("errors", "folderPath"))
    assert_match(/cannot be written/, refused[1].dig("errors", "smtpPassword"))
    assert_empty refused[2]["errors"]
    lone = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("lib/compose_file").then((m) => done(m.validate({ ...#{DEFAULTS.to_json}, sharePassword: "a\\ud800b", library: "share",
        shareServer: "nas", shareName: "s", shareUser: "u" }).sharePassword || null));
    JS
    assert_match(/cannot be written/, lone.to_s)

    choose "A folder on this machine"
    find("summary", text: "Mail and HTTPS (optional)").click
    fill_in "compose-smtp-address", with: "smtp.example.net"
    assert_selector "#compose-app-host-error", text: "Required with an SMTP server"
    fill_in "compose-app-host", with: "https://maker.example.net"
    assert_selector "#compose-app-host-error", text: "no https://"
    fill_in "compose-app-host", with: "maker.example.net"
    assert_button "Download", disabled: false
  end

  # ---- download, privacy, phone -------------------------------------------------------------------

  # The Blob URL and the click are captured rather than followed, so the test reads what would be
  # saved without depending on the browser's download handling.
  test "Download saves the preview as docker-compose.yml" do
    open_page
    page.execute_script(<<~JS)
      window.__saved = [];
      const blobs = new Map();
      const create = URL.createObjectURL.bind(URL);
      URL.createObjectURL = (blob) => { const url = create(blob); blobs.set(url, blob); return url };
      HTMLAnchorElement.prototype.click = function () { window.__saved.push({ name: this.download, blob: blobs.get(this.href) }) };
    JS
    click_on "Download"
    saved = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const s = window.__saved;
      Promise.all(s.map((x) => x.blob.text())).then((texts) => done(s.map((x, i) => [x.name, texts[i]])));
    JS
    assert_equal [ [ "docker-compose.yml", preview ] ], saved
  end

  # NOTHING TYPED LEAVES THE TAB: no fetch, XHR or beacon, no resource request carrying a value, and
  # no navigation -- Enter in a field included, which is what a <form> would have turned into a URL.
  test "nothing typed into the page is sent anywhere" do
    open_page
    start = current_url
    page.execute_script(<<~JS)
      window.__sent = [];
      const record = (kind) => (...args) => { window.__sent.push([kind, String(args[0])]) };
      const fetch0 = window.fetch;
      window.fetch = (...args) => { record("fetch")(...args); return fetch0(...args) };
      const open0 = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (...args) { record("xhr")(args[1]); return open0.apply(this, args) };
      navigator.sendBeacon = (...args) => { record("beacon")(...args); return true };
    JS
    marker = "zq7secret"
    fill_in "compose-folder-path", with: "/mnt/#{marker}"
    fill_in "compose-port", with: "8081"
    choose "A network share (SMB)"
    fill_in "compose-share-server", with: "nas"
    fill_in "compose-share-name", with: "share"
    fill_in "compose-share-user", with: "#{marker}-user"
    fill_in "compose-share-password", with: "#{marker}-password"
    find_field("compose-share-password").send_keys(:enter)
    find("summary", text: "Mail and HTTPS (optional)").click
    fill_in "compose-smtp-address", with: "smtp.example.net"
    fill_in "compose-app-host", with: "maker.example.net"
    fill_in "compose-smtp-user", with: "#{marker}-smtp-user"
    fill_in "compose-smtp-password", with: "#{marker}-smtp"
    find_field("compose-smtp-password").send_keys(:enter)
    uncheck "The Tools gallery"
    assert_selector ".compose-preview", text: "#{marker}-password"

    assert_equal start, current_url, "the page navigated"
    assert_equal [], page.evaluate_script("window.__sent"), "the page sent a request while it was typed into"
    leaked = page.evaluate_script("performance.getEntriesByType('resource').map((e) => e.name)").grep(/#{marker}/)
    assert_empty leaked, "a request URL carried a typed value"
  end

  # THE GUTTER IS THE SHELL'S, 12px below 720px on every page (shell.css), not one of this page's own;
  # what is asserted is that both panels stay inside it. Edges are measured against clientWidth, which
  # leaves out the 15px scrollbar the Linux CI Chrome draws and the Mac's does not.
  test "at phone width the file stacks under the form, inside the shell's gutter, and nothing scrolls sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      open_page
      fill_in "compose-folder-path", with: "/mnt/user/a/very/long/path/that/would/push/a/page/sideways/if/the/file/could/widen/it"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
             "the page scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      gutter = page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('main#main')).paddingLeft)")
      assert_operator gutter, :>=, 12
      width = page.evaluate_script("document.documentElement.clientWidth")
      %w[.compose-form .compose-output].each do |box|
        left, right = page.evaluate_script("(r => [r.left, r.right])(document.querySelector('#{box}').getBoundingClientRect())")
        assert_operator left, :>=, gutter - 0.5, "#{box} starts inside the gutter"
        assert_operator right, :<=, width - gutter + 0.5, "#{box} ends past the gutter"
      end
      form_bottom = page.evaluate_script("document.querySelector('.compose-form').getBoundingClientRect().bottom")
      output_top = page.evaluate_script("document.querySelector('.compose-output').getBoundingClientRect().top")
      assert_operator output_top, :>=, form_bottom, "the file should stack under the form on a phone"
      assert page.evaluate_script("(p => p.scrollWidth > p.clientWidth)(document.querySelector('.compose-preview'))"),
             "the long line should scroll inside the preview"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end
end
