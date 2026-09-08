require "test_helper"
require "support/gerber_fixture"
require "support/public_fixture"

module Web
  # Gerber and Excellon previews: the file page's `:gerber` branch (FilesController#show,
  # files/show.html.erb) and the two project pages' NOT rendering a viewer — since 2026-09-06 a
  # Gerber is a file like any other there and the board renders only on its own file page.
  #
  # SHARE IS PINNED FOR THE WHOLE FILE, and unlike kicanvas_preview_test.rb that is not optional
  # scope. A `.gbrjob` is READ ON THE SERVER — `Maker::GerberSets.job_layer_names` opens it through
  # the port to learn which layers the export claims — so a fixture built with bare `nodes.create!`
  # has nothing behind it on s3 (the stub bucket holds no object) or chunk_remote (no version), and
  # the job branch would fall back to the directory on every leg for a reason that has nothing to do
  # with the code under test. `use_fresh_share_library!` BEFORE any node is created, per the house
  # rule; never `ensure_library_folder!`, which is a real mkdir through the port.
  #
  # WHAT ONLY A BROWSER CAN SEE — that the vendored bundle actually parses these bytes and paints an
  # SVG — is test/system/gerber_test.rb's job. This file is about which markup the server produces.
  class GerberPreviewTest < ActionDispatch::IntegrationTest
    include GerberFixture
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "gerber")
      sign_in_as(@user)
    end

    def layers_of(selector)
      JSON.parse(css_select(selector).first["data-gerber-layers-value"])
    end

    # --- the file page -----------------------------------------------------------

    test "a .gtl file page renders the viewer at rest, single, pointed at its own named blob" do
      node = write_gerber!(name: "board.gtl")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".model-viewer.gerber-viewer[data-controller=?]", "gerber"
      assert_select ".gerber-viewer[data-gerber-single-value=?]", "true"
      assert_select ".gerber-viewer .model-viewer-stage[data-gerber-target=?]", "stage"
      # THE 3D VIEWER'S CHROME: a launch button in the bar, the three actions beside it, and the
      # poster underneath with the download — nothing is fetched until the button is clicked.
      assert_select ".gerber-viewer .mv-launch button", text: "View layer"
      assert_select ".gerber-viewer .mv-actions button", text: "Fit"
      assert_select ".gerber-viewer .mv-actions button", text: "Fullscreen"
      assert_select ".gerber-viewer .mv-actions button", text: "✕ Image"
      assert_select ".gerber-viewer .model-viewer-fallback a[href=?]", blob_file_path(node.node_id, download: 1)
      assert_equal [ { "name" => "board.gtl",
                       "url" => named_blob_file_path(node.node_id, filename: "board.gtl") } ],
                   layers_of(".gerber-viewer")
      # NO SIDE BUTTONS AND NO TOOLS SPAN ON A SINGLE LAYER: renderLayers produces one picture, so
      # Top and Bottom would be two buttons showing the same thing, and a toggle for the one layer
      # would only blank the stage.
      assert_select ".gerber-viewer [data-gerber-target=?]", "side", 0
      assert_select ".gerber-viewer [data-gerber-target=?]", "tools", 0
    end

    # THE POSTER IS THE SERVER-RENDERED THUMBNAIL SINCE 2026-09-07 — tracespace's own picture under
    # node (Maker::Previews::Gerber), so the resting page, the grid cell and the launched viewer are
    # one render. Before this the branch's own header said "Gerbers have no thumbnail" and the
    # poster was a sentence and a Download button.
    #
    # THE ROW IS BUILT THROUGH THE PORT'S OWN TOKEN, not off the node's content_hash column:
    # `FilesController#show` resolves `@thumbnail` by `@info.content_token`, which is the port's
    # answer, and a row keyed on anything else is simply not the current one (files_flow_test.rb's
    # ready-poster shape exactly).
    test "a ready thumbnail becomes the Gerber viewer's poster" do
      node = write_gerber!(name: "board.gtl")
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node.node_id,
                                              name: "board.gtl", version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png",
                           content_type: "image/png")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".gerber-viewer .model-viewer-fallback img.preview-image", 1
      assert_select ".gerber-viewer .model-viewer-fallback img[alt=?]", "Preview of board.gtl"
    end

    # AND NOT BEFORE IT IS READY. A pending row must render the sentence alone, never a broken
    # image — the same guard the :model3d poster carries, and the state every Gerber is in for the
    # first few seconds after it lands.
    test "a pending thumbnail leaves the poster as it was" do
      node = write_gerber!(name: "pending.gtl")
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
      Maker::Previews::Enqueue.call(user: @user, node_id: node.node_id, name: "pending.gtl",
                                    version_id: token, kind: "thumbnail")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".gerber-viewer .model-viewer-fallback img", 0
      assert_select ".gerber-viewer .model-viewer-fallback a[href=?]",
                    blob_file_path(node.node_id, download: 1)
    end

    # THE FILE PAGE IS ABOUT ITS OWN FILE, even when the whole board sits beside it. A file page that
    # quietly pulled in the neighbours would be showing something other than the file it is named
    # for; the board's own pages are the `.gbrjob`'s and a zipped export's.
    test "a .gtl file page ignores its siblings" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)

      get file_path(set[:gtl].node_id)
      assert_response :success
      assert_equal [ "board.gtl" ], layers_of(".gerber-viewer").map { |l| l["name"] }
    end

    test "an Excellon drill file reaches the same branch" do
      node = write_gerber!(name: "board.drl", body: MINIMAL_DRILL)

      get file_path(node.node_id)
      assert_response :success
      assert_select ".model-viewer.gerber-viewer[data-controller=?]", "gerber"
    end

    # --- the .gbrjob file page ---------------------------------------------------

    # A JOB FILE IS NOT A LAYER — it is JSON naming the set — so the only honest render of its page
    # is the BOARD it names. Its layers are the siblings it lists and NOTHING else: the stray file
    # below is in the same folder, is a real Gerber, and must not be stacked.
    test "a .gbrjob file page stacks the siblings the job names, and only those" do
      dir = gerber_dir!(name: "pcb")
      write_gerber_set!(parent_node_id: dir.node_id)
      write_gerber!(name: "old-revision.gtl", parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl", "board.gbl", "board.drl"))

      get file_path(job.node_id)
      assert_response :success
      assert_equal %w[board.drl board.gbl board.gtl], layers_of(".gerber-viewer").map { |l| l["name"] }
      # A STACKUP, SO THE SIDE BUTTONS AND THE TOOLS SPAN ARE THERE and single is false — and the
      # launch button says "View board" rather than "View layer".
      assert_select ".gerber-viewer[data-gerber-single-value=?]", "false"
      assert_select ".gerber-viewer .mv-launch button", text: "View board"
      assert_select ".gerber-viewer [data-gerber-target=?]", "side", 2
      assert_select ".gerber-viewer [data-gerber-target=?]", "tools", 1
    end

    # THE MANIFEST IS NEVER ITSELF STACKED. tracespace's Gerber parser turns JSON into a junk layer
    # rather than raising, so this exclusion has no loud failure mode to protect it.
    test "a .gbrjob never appears in its own layer list" do
      dir = gerber_dir!(name: "pcb")
      write_gerber_set!(parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl", "board.gbl", "board.drl", "board.gbrjob"))

      get file_path(job.node_id)
      assert_response :success
      assert_not_includes layers_of(".gerber-viewer").map { |l| l["name"] }, "board.gbrjob"
    end

    # THE EXPORTED-THEN-RENAMED CASE: a job naming files this folder does not hold falls back to the
    # directory rather than rendering an empty stage beside a full file list.
    test "a .gbrjob naming nothing this folder holds falls back to every Gerber beside it" do
      dir = gerber_dir!(name: "pcb")
      write_gerber_set!(parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("somewhere-else.gtl"))

      get file_path(job.node_id)
      assert_response :success
      assert_equal %w[board.drl board.gbl board.gtl], layers_of(".gerber-viewer").map { |l| l["name"] }
    end

    test "a .gbrjob with no Gerbers beside it says so instead of mounting an empty viewer" do
      job = write_gerber!(name: "lonely.gbrjob", body: gerber_job("board.gtl"))

      get file_path(job.node_id)
      assert_response :success
      assert_select ".gerber-viewer", 0
      assert_select "p.muted", text: /No Gerber layers/
    end

    # --- a zipped export's own file page -----------------------------------------

    # THE ZIP IS THE BOARD. A Fusion "CAM outputs" archive reaches the :gerber branch by a READ (the
    # only preview kind that does), renders as a STACKUP, and hands the browser ONE entry: the zip's
    # own URL plus the member paths JSZip pulls out of it. Rails extracts nothing.
    test "a .zip holding a Gerber export renders the board from one archive entry" do
      zip = write_gerber_zip!

      get file_path(zip.node_id)
      assert_response :success
      assert_select ".model-viewer.gerber-viewer[data-controller=?]", "gerber"
      # A STACKUP, LIKE A .gbrjob's PAGE: an export is a whole board, so Top and Bottom are both real
      # pictures rather than two buttons showing the same one.
      assert_select ".gerber-viewer[data-gerber-single-value=?]", "false"
      assert_select ".gerber-viewer .mv-launch button", text: "View board"
      assert_select ".gerber-viewer [data-gerber-target=?]", "side", 2
      assert_select ".gerber-viewer [data-gerber-target=?]", "tools", 1
      assert_equal [ { "name" => "board.zip",
                       "url" => named_blob_file_path(zip.node_id, filename: "board.zip"),
                       "archive" => true,
                       "members" => fusion_zip_members } ],
                   layers_of(".gerber-viewer")
    end

    # A ZIP IS ONLY A BOARD WHEN ITS CONTENTS SAY SO — `preview_kind` still answers from the NAME for
    # the whole vocabulary, and a zip of source is no more a board than a `.txt` is.
    test "a .zip of nothing relevant renders no gerber viewer" do
      zip = write_gerber_zip!(name: "firmware.zip", body: gerber_zip("src/main.c" => "int main(){}"))

      get file_path(zip.node_id)
      assert_response :success
      assert_select ".gerber-viewer", 0
    end

    test "a .txt file page does not render the gerber branch" do
      node = write_gerber!(name: "notes.txt", body: "plain")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".gerber-viewer", 0
    end

    # --- the project pages ----------------------------------------------------------

    # NO BOARD ON A PROJECT PAGE (2026-09-06, at the user's request): a folder's Gerbers and a zipped
    # export are ordinary file rows there, linking to the file page where the board renders. The
    # Fabrication panel that grouped them into inline viewers is gone, and this is the test that
    # says so — a panel quietly re-added under any name mounts `data-controller="gerber"`.
    test "the project page mounts no board viewer and lists a folder's Gerbers as files" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      set = write_gerber_set!(parent_node_id: dir.node_id)
      zip = write_gerber_zip!(parent_node_id: dir.node_id)

      get project_path(project)
      assert_response :success
      assert_select "[data-controller=?]", "gerber", 0
      assert_select ".fabrication-panel", 0
      assert_select "a[href=?]", file_path(set[:gtl].node_id)
      assert_select "a[href=?]", file_path(zip.node_id)
    end

    # THE PROJECT PAGE MOUNTS NO BOARD RENDER, and since stage 4, S4-5 that is because the render
    # lives ON THE LAYER'S OWN PUBLIC PAGE rather than because a visitor cannot have one. The
    # sentence this comment used to end on — "there is no public FILE page to mount one on" — was
    # true until S4-5 and is deleted rather than left to be relied on: the two cells now answer two
    # questions, the NAME opening `public_file_view_path` (where the viewer is) and Download still
    # naming the bytes. What stays true is that a board on a project page costs no visitor a parse
    # they did not ask for, which is why the Fabrication panel went in the first place.
    test "the public page mounts no board viewer and links each layer to its own page" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "public")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      set = write_gerber_set!(parent_node_id: dir.node_id)
      reset!

      get public_project_path("gerber", project.slug)
      assert_response :success
      assert_select "[data-controller=?]", "gerber", 0
      assert_select "a[href=?]", public_file_view_path("gerber", project.slug, set[:gtl].node_id)
      assert_select "a[href=?]", public_file_path("gerber", project.slug, set[:gtl].node_id, download: 1)
    end

    private

    # The public page must be read with NO session — `setup` signs the owner in, and
    # Public::BaseController stands on ActionController::Base and never reads one anyway, so the
    # assertions above should not depend on which state the cookie jar happens to be in.
    def reset!
      delete destroy_user_session_path
    end
  end
end
