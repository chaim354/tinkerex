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
#   - The submit button reads "Create model", not "Import".
#   - importer_controller.js#renderSummary groups the count BY ROLE ("N model files · N images ·
#     N PDF"), never a bare total -- so "3 file" (the plan's literal assertion) never appears
#     anywhere in the DOM. The bundle below unzips to 2 model files + 1 PDF (the dotfile is
#     dropped), which renders as "2 model files · 0 images · 1 PDF".
#   - The file input on this page is a plain, unhidden `<input type="file" multiple>` (unlike
#     files/index.html.erb's uploader input, which carries `hidden`) -- so `attach_file` needs no
#     `make_visible:` at all, and per the README's environment-traps section, if it did, the
#     value would have to be `true`, never a CSS-selector string.
#   - Maker::FileAttachment has NO `node` association (only a bare `node_id` string column, no
#     `belongs_to :node`) -- resolving a name/parent from an attachment goes through a
#     node_id-keyed lookup, not `attachment.node`.
#
# MUTATION-CHECKED, both against a cleared tmp/dev-chunks* (README's warning: a stale
# content-addressed blob can make a broken mutation read green):
#   - Removing the dotfile guard (`if (!name) continue`, dropping `|| name.startsWith(".")`)
#     goes RED, but not at `refute_includes names, ".DS_Store"` -- it times out (30s) at the
#     EARLIER `file_attachments.reload.count == 3` wait, because a 4th file (.DS_Store) now
#     attaches and the count never reaches 3. The task doc anticipated exactly this ("RED on
#     refute_includes ... (and on the count)"): the count assertion runs first in this file and
#     is itself sensitive to the guard, so it catches the mutation before the name-list
#     assertion gets a chance to.
#   - Flattening the nesting (`dir: parts.join("/")` -> `dir: ""`) goes RED at EXACTLY ONE
#     assertion -- `assert_equal "tail_segments", @user.nodes.find_by!(...).name` -- with the
#     other 10 assertions in the same run green, confirming the flattening bug is invisible to
#     every other assertion in the file, which is why that one is written separately.
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

    click_on "Create model"

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

    # THE DOTFILE WAS SKIPPED. The controller drops entries whose basename starts with "." — macOS
    # puts __MACOSX/._foo in almost every real-world zip, and attaching those would litter every
    # imported model. Asserting the count alone would not catch it; asserting the names does.
    refute_includes names, ".DS_Store"

    # ROLES COME FROM THE SERVER, not from the browser. importer_controller.js has its own
    # extension→role table (a third hand-copy, already drifted twice — the Forgejo record), but only
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
