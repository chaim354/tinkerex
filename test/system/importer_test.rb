require "application_system_test_case"
require "zip"

# The Printables-bundle importer, driven through a real browser: ONE file selection -> JSZip unzips
# in the page -> a Model is created with a folder map -> every entry is uploaded through the chunk
# flow and attached with a server-derived role.
#
# models_import_test.rb covers the server sequence and says so plainly: "The actual in-browser
# unzip + byte upload is manual-smoke only (no JS runner)." This is that missing half. Nothing
# server-side can reach it -- the zip is never POSTed anywhere (§15: no zip bytes reach Rails), so
# the unzip either happens in the browser or not at all.
#
# The zip is BUILT HERE rather than committed as a fixture: the interesting variable is the entry
# layout (nested dir, mixed roles, a dotfile), and a generated archive shows that layout in the
# source instead of hiding it in a binary.
#
# MECHANICS RECONCILED AGAINST THE REAL VIEW (app/views/models/new.html.erb), per the task's Step
# 2 -- three things the plan wrote from the controller's targets/values did not match the markup:
#   - The title input has NO `name` attribute at all (this section is not a Rails form; the
#     controller drives everything via fetch()). It is reached by its wrapping label's text
#     ("Title"), not by "model[title]".
#   - The submit button is found by its `submit` target, not by its label: it read "Create model"
#     until 2026-11-02 and the UX audit renamed it "Import" to agree with the page's title — a
#     label is the view's to change, and what this file tests is the controller behind it.
#   - importer_controller.js#renderSummary groups the count BY ROLE ("N model files · N images ·
#     N PDF"), never a bare total -- so "3 file" (the plan's literal assertion) never appears
#     anywhere in the DOM. The bundle below unzips to 2 model files + 1 PDF (the dotfile is
#     dropped), which renders as "2 model files · 0 images · 1 PDF".
#   - The file input on this page is a plain, unhidden `<input type="file" multiple>` (unlike
#     the top bar's uploader input, layouts/_topbar_upload.html.erb, which carries `hidden` -- and
#     being hidden is also why the locator-less attach below does not find it beside this one;
#     verified green with both on the page) -- so `attach_file` needs no
#     `make_visible:` at all, and per the README's environment-traps section, if it did, the
#     value would have to be `true`, never a CSS-selector string.
#   - Maker::FileAttachment has NO `node` association (only a bare `node_id` string column, no
#     `belongs_to :node`) -- resolving a name/parent from an attachment goes through a
#     node_id-keyed lookup, not `attachment.node`.
#
# MUTATION-CHECKED. The unzip moved out of importer_controller.js into lib/zip_bundle.js on
# 2026-10-21 (shared with the top bar's Upload), so both mutations were RE-RUN there, on the
# share library this file now installs:
#   - Dropping the dot-segment half of the clutter rule (`isClutter` keeping only
#     `seg === "__MACOSX"`) goes RED at `assert_no_console_errors`, NOT at the count or at
#     `refute_includes names, ".DS_Store"`: share refuses the reserved dot-name as
#     FileLayer::NotFound, so its POST /files answers 404 (the browser logs it), the importer
#     skips that one file under its per-file rule, and the count still reaches 3. (On the
#     embedded chunk library this file used before, .DS_Store attached and the count wait timed
#     out instead.)
#   - Flattening the nesting (`entries.push({ name: f.name, dir, … })` -> `dir: ""`) goes RED at
#     EXACTLY ONE assertion in this test -- `assert_equal "tail_segments", @user.nodes.find_by!(...).name`
#     -- confirming the flattening bug is invisible to every other assertion here, which is why
#     that one is written separately. (The wrapper test below goes red too, on `"parts"`.)
class ImporterTest < ApplicationSystemTestCase
  setup do
    # A hermetic share library, where this pinned embedded chunk. The subject is the in-browser
    # unzip and the attach that follows, not the backend underneath it.
    @root = use_fresh_share_library!
    @user = sign_in_as("importer@example.com")
    @zip = build_bundle
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  teardown { @zip&.close! }

  test "one zip selection becomes a model with its files unzipped in-browser and attached" do
    visit new_model_path

    assert_selector "[data-controller='importer']"
    fill_in "Title", with: "Articulated Dragon"
    attach_file(@zip.path)

    # The controller summarises the selection BEFORE anything is uploaded. Asserting it first
    # separates "the unzip worked" from "the uploads worked" — if this passes and the next block
    # fails, JSZip is fine and the upload loop is not.
    assert_selector "[data-importer-target='summary']", text: "2 model files · 0 images · 1 PDF"

    find("[data-importer-target='submit']").click

    model = nil
    assert_eventually("the model was never created") do
      model = @user.maker_models.find_by(title: "Articulated Dragon")
      model.present?
    end

    # `file_attachments`, NOT `attachments` — verified against app/models/maker/model.rb:13, where it
    # is declared with an `-> { order(:position) }` scope.
    assert_eventually("not every bundle entry was attached") do
      model.file_attachments.reload.count == 3
    end

    # Maker::FileAttachment has NO `node` association — only a bare `node_id` string column (its
    # own model carries no `belongs_to :node`; the plan's `a.node` does not exist). Resolve the
    # Node rows once, by id, the same way FilesController and the model's own `derived_cover_node_id`
    # do it.
    nodes_by_id = @user.nodes.where(node_id: model.file_attachments.map(&:node_id)).index_by(&:node_id)

    names = model.file_attachments.map { |a| nodes_by_id.fetch(a.node_id).name }.sort
    assert_equal [ "dragon.stl", "instructions.pdf", "tail.stl" ], names

    # THE DOTFILE WAS SKIPPED. lib/zip_bundle.js drops any entry with a path segment starting with
    # "." — macOS puts __MACOSX/._foo in almost every real-world zip, and attaching those would
    # litter every imported model. On share the port refuses the name anyway, so a broken rule
    # shows here as a logged 404 (assert_no_console_errors below) — see the header's mutation note.
    refute_includes names, ".DS_Store"

    # ROLES COME FROM THE SERVER, not from the browser. importer_controller.js has its own
    # extension→role table (a third hand-copy, already drifted twice — the record), but only
    # node_id and cover are POSTed and Maker::FileAttachment.role_for re-derives authoritatively.
    # This pins that the persisted role is the server's answer, which is what makes the JS copy's
    # drift harmless.
    roles = model.file_attachments.to_h { |a| [ nodes_by_id.fetch(a.node_id).name, a.role ] }
    assert_equal "model",        roles.fetch("dragon.stl")
    assert_equal "model",        roles.fetch("tail.stl")
    assert_equal "instructions", roles.fetch("instructions.pdf")

    # NESTED PATHS BECAME REAL FOLDERS, not flattened names. tail.stl was at
    # tail_segments/tail.stl, so its node's parent must be a folder called tail_segments —
    # flattening would silently collapse a 40-part bundle into one directory.
    tail_att = model.file_attachments.find { |a| nodes_by_id.fetch(a.node_id).name == "tail.stl" }
    tail = nodes_by_id.fetch(tail_att.node_id)
    assert_equal "tail_segments", @user.nodes.find_by!(node_id: tail.parent_node_id).name

    assert_no_console_errors
  end

  # THE WRAPPER FOLDER IS DROPPED (lib/zip_bundle.js, shared with the top bar since 2026-10-21): a
  # zip whose every entry sits under one top-level directory imports without that level, so the
  # model's folder does not hold a single folder of the same name. MUTATION-CHECKED: forcing
  # `wrapped = false` in zip_bundle.js reddens the parent assertion below (the STL lands one level
  # deeper, under `widget/`).
  test "a zip wrapped in one folder imports without the wrapper" do
    zip = Tempfile.new([ "widget", ".zip" ])
    zip.close
    Zip::File.open(zip.path, create: true) do |z|
      z.get_output_stream("widget/widget.stl")       { |io| io.write("solid w\nendsolid\n") }
      z.get_output_stream("widget/parts/knob.stl")   { |io| io.write("solid k\nendsolid\n") }
      z.get_output_stream("__MACOSX/widget/._x.stl") { |io| io.write("junk") }
    end

    visit new_model_path
    fill_in "Title", with: "Widget"
    attach_file(zip.path)
    assert_selector "[data-importer-target='summary']", text: "2 model files · 0 images · 0 PDF"
    find("[data-importer-target='submit']").click

    model = nil
    assert_eventually("the model was never created") do
      model = @user.maker_models.find_by(title: "Widget")
      model.present? && model.file_attachments.reload.count == 2
    end
    # By the model's folder ID, never by name: unwrapped or not, the parent would be CALLED `widget`.
    widget = @user.nodes.find_by!(node_id: model.file_attachments.map(&:node_id), name: "widget.stl")
    assert_equal model.reload.folder_node_id, widget.parent_node_id
    knob = @user.nodes.find_by!(node_id: model.file_attachments.map(&:node_id), name: "knob.stl")
    assert_equal "parts", @user.nodes.find_by!(node_id: knob.parent_node_id).name
    assert_no_console_errors
  ensure
    zip&.close!
  end

  # A RUN THAT SKIPPED A FILE STAYS AND SAYS SO (UX audit B7). The importer wrote "imported N,
  # skipped M" into its status line and navigated to the model on the very next line, so the report
  # was never seen; now it stays on this page, the status says what landed with a link to the model,
  # the alert names what did not and why, and the submit stays disabled — the model exists, and a
  # second press would make another. The refusal is the share door's own clobber answer, handed
  # back for one file by replacing `fetch` in the page: the real collision cannot be staged, since
  # the model's folder is made fresh by the import itself.
  #
  # MUTATION-CHECKED (2026-11-02): with importer_controller.js navigating to the model whenever
  # anything landed (the old `window.location.href = …` after a partial run), the status wait goes
  # RED — the page has moved on to the model, so there is no status line left to read; restored,
  # green.
  test "an import that skipped a file stays on the page with the report" do
    visit new_model_path
    page.execute_script(<<~JS)
      const real = window.fetch
      window.fetch = (url, opts = {}) => {
        const file = opts.body instanceof FormData ? opts.body.get("file") : null
        if (file && file.name === "tail.stl") {
          return Promise.resolve(new Response(JSON.stringify({ error: '"3D models/x/tail_segments/tail.stl" already exists' }),
                                              { status: 422, headers: { "Content-Type": "application/json" } }))
        }
        return real(url, opts)
      }
    JS
    fill_in "Title", with: "Articulated Dragon"
    attach_file(@zip.path)
    assert_selector "[data-importer-target='summary']", text: "2 model files · 0 images · 1 PDF"
    find("[data-importer-target='submit']").click

    assert_selector "[data-importer-target='status']", text: "Imported 2 of 3 files.", wait: 30
    model = @user.maker_models.find_by!(title: "Articulated Dragon")
    assert_selector "[data-importer-target='status'] a[href$='#{model_path(model)}']", text: "Open the model"
    assert_equal "This one was not added: tail.stl (the folder already has a file with that name).",
                 find(".flash-stack .flash.flash-alert .flash-text").text
    assert_current_path new_model_path
    assert_selector "[data-importer-target='submit'][disabled]"
    assert_equal 2, model.file_attachments.count
    assert_no_console_errors
  end

  # A MODEL THE SERVER COULD NOT MAKE IS EXPLAINED, NEVER SHOWN AS A CODE. ModelsController answers an
  # unreachable library with `{ error: "fetch_error" }` at 503 — a code, which the importer printed
  # as "Import failed: fetch_error" — and a name taken mid-import with a sentence at 422. The first
  # gets the upload doors' wording (lib/chunk_upload.js#failureReason), the second is the server's
  # sentence; the submit comes back after each, since no model was made. Answered by replacing
  # `fetch` for `POST /models.json` in the page: neither state can be staged on demand.
  #
  # MUTATION-CHECKED (2026-11-02): with importer_controller.js#createFailure printing
  # `e.serverError` before anything else (as the catch did), the first alert reads "Import failed:
  # fetch_error" — RED; restored, green.
  test "a model the server could not make is explained, never shown as a code" do
    visit new_model_path
    page.execute_script(<<~JS)
      window.__modelAnswer = { status: 503, body: { error: "fetch_error" } }
      const real = window.fetch
      window.fetch = (url, opts = {}) => String(url).includes("/models.json")
        ? Promise.resolve(new Response(JSON.stringify(window.__modelAnswer.body),
                                       { status: window.__modelAnswer.status, headers: { "Content-Type": "application/json" } }))
        : real(url, opts)
    JS
    fill_in "Title", with: "Articulated Dragon"
    attach_file(@zip.path)
    assert_selector "[data-importer-target='summary']", text: "2 model files · 0 images · 1 PDF"

    find("[data-importer-target='submit']").click
    assert_equal "Import failed: the library could not be reached. Try again in a moment.",
                 find(".flash-stack .flash.flash-alert .flash-text").text
    assert_no_text "fetch_error"
    find(".flash-stack .flash.flash-alert .flash-close").click
    assert_no_selector ".flash-stack .flash.flash-alert"

    page.execute_script("window.__modelAnswer = { status: 422, body: { error: 'That name was just taken — try again.' } }")
    find("[data-importer-target='submit']:not([disabled])").click
    assert_equal "Import failed: that name was just taken — try again.",
                 find(".flash-stack .flash.flash-alert .flash-text").text
    assert_selector "[data-importer-target='submit']:not([disabled])"
    refute @user.maker_models.exists?, "a model was made"
    assert_no_console_errors(ignoring: [ /fetch_error/, /just taken/ ])
  end

  private

    # A Printables-shaped bundle: a model at the root, a nested model, a PDF, and the macOS dotfile
    # that ships with nearly every real download.
    def build_bundle
      file = Tempfile.new([ "bundle", ".zip" ])
      file.close
      Zip::File.open(file.path, create: true) do |zip|
        zip.get_output_stream("dragon.stl")               { |io| io.write("solid dragon\nendsolid\n") }
        zip.get_output_stream("tail_segments/tail.stl")   { |io| io.write("solid tail\nendsolid\n") }
        zip.get_output_stream("instructions.pdf")         { |io| io.write(pdf_bytes) }
        zip.get_output_stream(".DS_Store")                { |io| io.write("\x00\x01junk") }
      end
      file
    end

    # A real (tiny) PDF rather than random bytes: the attach step dispatches
    # ExtractPdfMetadataJob for the `instructions` role, and handing it a non-PDF makes this test
    # fail inside a job for a reason that has nothing to do with importing.
    def pdf_bytes
      Rails.root.join("test/fixtures/files/sample.pdf").binread
    end

    def assert_eventually(message, timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
