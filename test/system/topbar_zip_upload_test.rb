require "application_system_test_case"
require "zip"

# A MODEL ZIP UPLOADED THROUGH THE TOP BAR UNPACKS (2026-10-21; docs/superpowers/specs/
# 2026-10-20-zip-upload-unpacks-models-design.md). Only a browser can see this: the zip is read by
# JSZip in the page and never reaches the server, so no request test can tell an unpacked zip from
# a skipped one. Share only (use_fresh_share_library!), for the README's reason — the chunk flow's
# copy of the branch is in uploader_test.rb and shares lib/zip_unpack.js with this one.
#
# FIXTURES ARE BUILT IN A Dir.mktmpdir, never under the repo: Selenium cannot read a file under
# ~/Desktop (macOS TCC; test/system/README.md), and JSZip reads the bytes.
#
# MUTATION-CHECKED (2026-10-21; each reverted, and the file re-run green after):
#   - splitSelection's `if (firstModel)` → `if (false)` in lib/zip_unpack.js: both unpack tests RED
#     at `eventually` with "the zip was never unpacked" (no model zip, so the form posted the zip
#     whole); the no-model-zip test stayed green.
#   - `const wrapped = false` in lib/zip_bundle.js: the first test RED at "wrapper not dropped" — the
#     entries kept their `iris/` level, so gate.stl went one folder deeper; the other two green.
#   - `return parent` as the first line of Files::UnpacksController#destination: the project test RED
#     on `["models", <project folder>]` vs `["stargate", <Projects>]` — `iris/` made at the project
#     root, the sweep's inbox; the other two green.
#   - THE LAZY INFLATE: unpackZip handing `upload` the LISTED entry instead of `await entry.load()`
#     (lib/zip_unpack.js): both unpack tests RED — the first at `assert_current_path` (every entry
#     refused, so nothing landed and there was no folder to open), the project test at "gate.stl
#     never landed"; the no-model test green.
#   - EVERY ZIP A MODEL ZIP: splitSelection's `if (firstModel)` → `if (firstModel || true)`, with
#     `firstModel: firstModel || entries[0]` (lib/zip_unpack.js): the no-model test RED at the listing
#     assertion — firmware.zip unpacked, the page opened on main.c and README.md; the other two green.
#     First run against a bare `assert_text`, which PASSED on the status line "Unpacking firmware.zip
#     — …" and left only the find_by! to catch it; that is why the wait is scoped to `main#main`.
class TopbarZipUploadTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("zip-upload-#{SecureRandom.hex(4)}@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
    @dir = Dir.mktmpdir("topbar_zip")
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    FileLayer.reset!
  end

  test "a zip holding a model unpacks into a folder named after it, without the zip" do
    zip = build_zip("iris.zip",
                    "iris/gate.stl" => "solid gate\nendsolid\n",
                    "iris/parts/ring.stl" => "solid ring\nendsolid\n",
                    "iris/readme.txt" => "hello",
                    "__MACOSX/iris/._gate.stl" => "junk")
    visit files_path(folder: @cad.node_id)
    attach_file("topbar_upload_file", zip, make_visible: true)

    folder = eventually("the zip was never unpacked") do
      @user.nodes.present.find_by(parent_node_id: @cad.node_id, name: "iris", kind: "dir")
    end
    assert_current_path files_path(folder: folder.node_id), wait: 30
    assert @user.nodes.present.exists?(name: "gate.stl", parent_node_id: folder.node_id), "wrapper not dropped"
    assert @user.nodes.present.exists?(name: "readme.txt", parent_node_id: folder.node_id)
    ring = @user.nodes.present.find_by!(name: "ring.stl")
    assert_equal "parts", @user.nodes.find_by!(node_id: ring.parent_node_id).name
    refute @user.nodes.present.exists?(name: "iris.zip"), "the zip itself was uploaded too"
    refute @user.nodes.present.exists?(name: "._gate.stl")
    assert_no_console_errors
  end

  test "a zip with no model file uploads as the zip itself" do
    zip = build_zip("firmware.zip", "main.c" => "int main(void) { return 0; }", "README.md" => "x")
    visit files_path(folder: @cad.node_id)
    attach_file("topbar_upload_file", zip, make_visible: true)

    # IN THE LISTING, not anywhere on the page: the top bar's status line names the zip while one is
    # being unpacked, which a bare `assert_text` accepted (the every-zip-a-model mutation, header).
    assert_selector "main#main", text: "firmware.zip"
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: "firmware.zip").parent_node_id
    refute @user.nodes.present.exists?(name: "main.c")
    assert_no_console_errors
  end

  test "at a project's folder the zip unpacks into its models folder" do
    folder = FileLayer.current.mkdir(@user, parent_node_id: FileLayer.current.mkdir(@user, parent_node_id: nil, name: "Projects").node_id,
                                            name: "stargate")
    project = @user.maker_projects.create!(name: "Stargate")
    project.update_column(:folder_node_id, folder.node_id)
    zip = build_zip("iris.zip", "gate.stl" => "solid gate\nendsolid\n")

    visit project_path(project)
    attach_file("topbar_upload_file", zip, make_visible: true)

    unpacked = eventually("the zip was never unpacked") { @user.nodes.present.find_by(name: "iris", kind: "dir") }
    models = @user.nodes.find_by!(node_id: unpacked.parent_node_id)
    assert_equal [ "models", folder.node_id ], [ models.name, models.parent_node_id ]
    eventually("gate.stl never landed") { @user.nodes.present.find_by(name: "gate.stl", parent_node_id: unpacked.node_id) }
    # The run ENDS by opening the unpacked folder; reading the console before then would miss
    # anything logged by the catalog nudge.
    assert_current_path files_path(folder: unpacked.node_id), wait: 30
    assert_no_console_errors
  end

  private

    def build_zip(name, entries)
      path = File.join(@dir, name)
      Zip::File.open(path, create: true) do |zip|
        entries.each { |entry, body| zip.get_output_stream(entry) { |io| io.write(body) } }
      end
      path
    end

    # Polls the DATABASE until the block answers something truthy, and returns it. Capybara's waits
    # only watch the DOM.
    def eventually(message, timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        value = yield
        return value if value
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
