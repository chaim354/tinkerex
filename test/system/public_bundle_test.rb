require "application_system_test_case"

# THE BUNDLE ACTUALLY BUILDING, IN A REAL BROWSER (stage 3, S3-6).
#
# THIS IS THE ONE PART OF THE SLICE NO REQUEST TEST CAN SEE. Rails' half — the manifest, the file
# URLs, the CSV — is covered at the request level (test/integration/web/public_bundle_test.rb); what
# only a browser can answer is whether `bundle_controller.js` actually mounts, whether `import JSZip
# from "jszip"` resolves through the importmap, whether `fetch` of the public file route is allowed
# by the CSP, and whether JSZip can turn a stream of Blobs into an archive. Every one of those
# fails SILENTLY in the other tiers: an unresolvable Stimulus identifier is a no-op with no console
# warning (test/stimulus_hygiene_test.rb's whole subject), and a blocked fetch is a rejected promise
# nothing on the server hears about.
#
# THE ASSERTION IS THE STATUS LINE, NOT A FILE ON DISK. The controller ends by clicking a
# `<a download>` on a Blob URL, and where headless Chrome puts that file — or whether it takes it at
# all — is a browser-configuration question this test has no business pinning. The status text is
# written only after `zip.generateAsync` has RESOLVED with a blob, so it is evidence the archive was
# built; the download itself is the browser's business.
#
# SHARE, PINNED BY `use_fresh_share_library!`: the fetches read real bytes, which a `create_node!`
# fixture has behind it only on share (test/support/public_fixture.rb's header), and this tier does
# not re-run the backend matrix (test/system/README.md).
#
# MUTATIONS (§15, test/system/README.md; both run for real and reverted — output in the PR):
#   * `import JSZip from "jszip"` → `from "jszip-x"`, a specifier the importmap has no pin for. The
#     controller never registers, so the click does nothing and the status line stays empty.
#   * `zip.file(file.path, await res.blob())` deleted. The status STILL reaches "Bundled 2 files" —
#     an archive of nothing is still an archive — which is precisely why this test also measures the
#     blob JSZip produced, and why "the status said so" is not on its own evidence the zip has
#     anything in it.
class PublicBundleTest < ApplicationSystemTestCase
  README = "# Desk Lamp\n\nA lamp that sits on a desk.\n".freeze
  STL = "solid base\nfacet normal 0 0 1\nendsolid base\n".freeze

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("bundle@example.com")
    # THE HANDLE COMES BEFORE THE PROJECT LEAVES `private` and locks once one is published —
    # Maker::Project's own validation, the ordering every public fixture in the suite carries.
    @user.update!(handle: "bundler")
    @project = @user.maker_projects.create!(name: "Desk Lamp", visibility: "public")
    # ROWS PLUS THE DIRECTORY THEY CLAIM TO BE. NEVER `ensure_library_folder!`: that is a real mkdir
    # through the port (the house rule, and §14a) — `project_folder_rows!` writes the rows and this
    # block gives them a storage_path and a real directory, exactly as shell_test.rb's own sweep
    # fixture does.
    folder = project_folder_rows!(@user, @project)
    @user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, @project.slug))
    @root.join(folder.storage_path).mkpath
    models = dir!("models", folder)
    # EXACTLY TWO FILES, ONE OF THEM IN A SUBFOLDER, so the count in the status line is unambiguous
    # and the zip carries a folder-relative path rather than two names at the root.
    file!("README.md", folder, README)
    file!("base.stl", models, STL)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def dir!(name, parent)
    create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "dir",
                 parent_node_id: parent.node_id, mtime: 1, size: 0)
  end

  # `create_node!` writes a literal "x" placeholder through the port's own path arithmetic; the real
  # body goes over it at whatever storage_path the catalog ended up holding, so the two can never
  # disagree about where the file is (test/support/public_fixture.rb does exactly this).
  def file!(name, parent, body)
    node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file",
                        parent_node_id: parent.node_id, mtime: 1, size: body.bytesize)
    @root.join(node.storage_path).binwrite(body)
    node
  end

  # WHAT THE ARCHIVE WEIGHED, WITHOUT TOUCHING THE FILESYSTEM. The controller's `<a download>` is
  # never attached to the document, so there is no element to read the blob back from, and where
  # headless Chrome files a download is a browser setting rather than a fact about this app. The
  # blob is captured on its way INTO `URL.createObjectURL`, which is the exact object
  # `zip.generateAsync` resolved with — a probe, not a stub: the original is still called, so the
  # controller behaves identically.
  CAPTURE_BLOB_SIZE = <<~JS.freeze
    window.__bundleBlobSize = null
    const original = URL.createObjectURL.bind(URL)
    URL.createObjectURL = (blob) => { window.__bundleBlobSize = blob.size; return original(blob) }
  JS

  test "a visitor builds the bundle in the browser" do
    visit public_project_path(@user.handle, @project.slug)

    assert_selector ".bundle button", text: "Download bundle (2 files"
    page.execute_script(CAPTURE_BLOB_SIZE)
    click_on "Download bundle"

    assert_selector ".bundle .muted", text: "Bundled 2 files"
    # THE COUNT PROVES BOTH FETCHES RAN; THE SIZE PROVES JSZIP RECEIVED BYTES. A zip of two empty
    # entries still reports "2 files" (this file's second mutation), so the status alone would pass
    # over an archive with nothing in it. A zip holding a README, an STL and bom.csv is a few
    # hundred bytes even compressed; 200 is a floor, not a measurement.
    size = page.evaluate_script("window.__bundleBlobSize")
    assert_operator size.to_i, :>, 200, "the archive handed to the visitor was #{size.inspect} bytes"
    assert_no_console_errors
  end
end
