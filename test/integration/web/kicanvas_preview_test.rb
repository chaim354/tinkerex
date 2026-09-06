require "test_helper"

module Web
  # KiCad schematics and boards (stage 3, S3-2): the file page's :kicanvas branch
  # (FilesController#preview_kind, files/show.html.erb) and the project page's Schematics section
  # (projects/_schematics.html.erb). BACKEND-NEUTRAL BY CONSTRUCTION: neither branch reads
  # anything backend-specific, so nodes are created directly with both content columns set
  # (files_toolbar_test.rb's own pattern) rather than through a real share library.
  #
  # NO REAL BYTES HERE ON PURPOSE. This is a request-level suite — nothing here drives a browser,
  # so nothing ever fetches the blob URL kicanvas_controller.js points at. Whether KiCanvas can
  # actually PARSE a real schematic is test/system/kicanvas_test.rb's job.
  class KicanvasPreviewTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "kicanvas-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    # BOTH content columns, for the reason files_toolbar_test.rb's own comment gives: content_hash
    # is what makes @info.content_token non-nil on share/s3, current_version_id is chunk's — and
    # files/show.html.erb's preview tree is entirely gated behind `@info.content_token.nil?`, so a
    # node missing both renders "No content yet." regardless of @kind.
    def file(node_id, name, parent_node_id: nil)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id:, mtime: 1_000_000_000,
                          size: 512, content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
    end

    test "a .kicad_sch file page renders the kicanvas branch, full controls, pointed at a named blob" do
      file("n-sch", "wiring.kicad_sch")

      get file_path("n-sch")
      assert_response :success
      assert_select ".kicanvas-stage[data-controller=?]", "kicanvas"
      # named_blob_file_path, NOT blob_file_path: KiCanvas reads the file's type off the URL's own
      # trailing extension (see files/show.html.erb's comment), so the URL must carry the real
      # name, not the opaque node id alone.
      assert_select ".kicanvas-stage[data-kicanvas-url-value=?]",
                    named_blob_file_path("n-sch", filename: "wiring.kicad_sch")
      assert_select ".kicanvas-stage[data-kicanvas-controls-value=?]", "full"
      assert_select ".kicanvas-stage [data-kicanvas-target=?]", "stage"
      assert_select ".kicanvas-stage [data-kicanvas-target=?]", "status"
    end

    test "a .kicad_pcb file page renders the same kicanvas branch" do
      file("n-pcb", "board.kicad_pcb")

      get file_path("n-pcb")
      assert_response :success
      assert_select ".kicanvas-stage[data-controller=?]", "kicanvas"
      assert_select ".kicanvas-stage[data-kicanvas-url-value=?]",
                    named_blob_file_path("n-pcb", filename: "board.kicad_pcb")
    end

    # THE ROUTE ITSELF (config/routes.rb's named_blob), not just that a page LINKS to it: :filename
    # is decorative to the server, never looked up — #blob still resolves the node from :id alone —
    # so the SAME bytes come back whatever the segment says, including a name that names nothing.
    #
    # A REAL upload (port_upload), not a bare `nodes.create!`: #blob streams the node's actual bytes
    # off disk, which a hand-built row has none of. use_fresh_share_library! HERE, not in setup —
    # every other test in this file only checks rendered HTML and never touches the port, so giving
    # them all an isolated library root would be scope they do not need.
    test "the named blob route serves the same bytes as the plain blob route, ignoring :filename" do
      use_fresh_share_library!
      id = port_upload("wiring.kicad_sch", "(kicad_sch (version 1))".b)

      get blob_file_path(id)
      plain_body = response.body

      get named_blob_file_path(id, filename: "wiring.kicad_sch")
      assert_response :success
      assert_equal plain_body, response.body

      get named_blob_file_path(id, filename: "this-name-matches-nothing.kicad_pcb")
      assert_response :success
      assert_equal plain_body, response.body
    end

    test "a .txt file page does not render the kicanvas branch" do
      file("n-txt", "notes.txt")

      get file_path("n-txt")
      assert_response :success
      assert_select ".kicanvas-stage", 0
    end

    test "the project page shows the Schematics panel with both files and one embed stage" do
      project = @user.maker_projects.create!(name: "Radio")
      folder = project_folder_rows!(@user, project)
      file("n-sch", "wiring.kicad_sch", parent_node_id: folder.node_id)
      file("n-pcb", "board.kicad_pcb", parent_node_id: folder.node_id)

      get project_path(project)
      assert_response :success
      assert_select "section.schematics-panel h2", text: "Schematics"
      assert_select ".schematics-panel .schematics-list li", 2
      assert_select ".schematics-panel a[href=?]", file_path("n-sch")
      assert_select ".schematics-panel a[href=?]", file_path("n-pcb")
      assert_select ".schematics-panel .badge", text: "schematic"
      assert_select ".schematics-panel .badge", text: "board"
      # ONE inline preview, "basic" controls — the file page's own is "full" (assertion above).
      assert_select ".schematics-panel .kicanvas-stage", 1
      assert_select ".schematics-panel .kicanvas-stage[data-kicanvas-controls-value=?]", "basic"
    end

    test "the project page shows no Schematics panel when the folder holds no KiCad files" do
      project = @user.maker_projects.create!(name: "Radio")
      folder = project_folder_rows!(@user, project)
      file("n-stl", "bracket.stl", parent_node_id: folder.node_id)

      get project_path(project)
      assert_response :success
      assert_select ".schematics-panel", 0
    end

    test "the Files pages list a .kicad_sch with its extension label, no poll cell, no filter chip" do
      file("n-sch", "wiring.kicad_sch")
      # A second, ORDINARY file so the type dropdown actually renders a group -- otherwise
      # ext_facets is empty regardless of kicad_sch's own exclusion (EXT_RE drops it either way)
      # and the "no chip" assertion below would pass vacuously, over an empty <select>.
      file("n-stl", "bracket.stl")

      get files_path(view: "grid")
      assert_response :success
      # THE GENERIC-CARD BRANCH, NOT THE THUMB-POLL ONE: _grid.html.erb's `if
      # Maker::Previews::Registry.for_filename(node.name).present?` is false for kicad_sch (no
      # renderer registered — files-preview.md), so the card carries file_menu_data only, never
      # thumb_cell_data's data-thumbs-target.
      assert_select "a[href=?]", file_path("n-sch")
      assert_select "a[href=?][data-thumbs-target]", file_path("n-sch"), 0

      get files_path(view: "list")
      assert_response :success
      assert_select "a[href=?][data-thumbs-target]", file_path("n-sch"), 0
      assert_select ".col-type", text: "KICAD_SCH"

      # NO CHIP: ext_facets filters candidate extensions through FilesController::EXT_RE before a
      # chip is ever built, and "kicad_sch" fails it (an underscore, and 9 characters).
      get files_path
      assert_select ".ext-picker option[value=kicad_sch]", 0
    end
  end
end
