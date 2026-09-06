require "test_helper"
require "support/gerber_fixture"
require "support/public_fixture"

module Web
  # Gerber and Excellon previews: the file page's `:gerber` branch (FilesController#preview_kind,
  # files/show.html.erb) and the Fabrication panel on the private and public project pages
  # (projects/_fabrication.html.erb, public/projects/_fabrication.html.erb).
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

    test "a .gtl file page renders the gerber stage, single, pointed at its own named blob" do
      node = write_gerber!(name: "board.gtl")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".gerber-stage[data-controller=?]", "gerber"
      assert_select ".gerber-stage[data-gerber-single-value=?]", "true"
      assert_select ".gerber-stage [data-gerber-target=?]", "stage"
      assert_select ".gerber-stage [data-gerber-target=?]", "status"
      assert_equal [ { "name" => "board.gtl",
                       "url" => named_blob_file_path(node.node_id, filename: "board.gtl") } ],
                   layers_of(".gerber-stage")
      # NO SIDE TOGGLE ON A SINGLE LAYER: renderLayers produces one picture, so Top and Bottom would
      # be two buttons showing the same thing.
      assert_select ".gerber-stage [data-gerber-target=?]", "side", 0
    end

    # THE FILE PAGE IS ABOUT ITS OWN FILE, even when the whole board sits beside it. The Fabrication
    # panel is where a board is a board; a file page that quietly pulled in the neighbours would be
    # showing something other than the file it is named for.
    test "a .gtl file page ignores its siblings" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)

      get file_path(set[:gtl].node_id)
      assert_response :success
      assert_equal [ "board.gtl" ], layers_of(".gerber-stage").map { |l| l["name"] }
    end

    test "an Excellon drill file reaches the same branch" do
      node = write_gerber!(name: "board.drl", body: MINIMAL_DRILL)

      get file_path(node.node_id)
      assert_response :success
      assert_select ".gerber-stage[data-controller=?]", "gerber"
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
      assert_equal %w[board.drl board.gbl board.gtl], layers_of(".gerber-stage").map { |l| l["name"] }
      # A STACKUP, SO THE SIDE TOGGLE IS THERE and single is false.
      assert_select ".gerber-stage[data-gerber-single-value=?]", "false"
      assert_select ".gerber-stage [data-gerber-target=?]", "side", 2
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
      assert_not_includes layers_of(".gerber-stage").map { |l| l["name"] }, "board.gbrjob"
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
      assert_equal %w[board.drl board.gbl board.gtl], layers_of(".gerber-stage").map { |l| l["name"] }
    end

    test "a .gbrjob with no Gerbers beside it says so instead of mounting an empty viewer" do
      job = write_gerber!(name: "lonely.gbrjob", body: gerber_job("board.gtl"))

      get file_path(job.node_id)
      assert_response :success
      assert_select ".gerber-stage", 0
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
      assert_select ".gerber-stage[data-controller=?]", "gerber"
      # A STACKUP, LIKE A .gbrjob's PAGE: an export is a whole board, so Top and Bottom are both real
      # pictures rather than two buttons showing the same one.
      assert_select ".gerber-stage[data-gerber-single-value=?]", "false"
      assert_select ".gerber-stage [data-gerber-target=?]", "side", 2
      assert_equal [ { "name" => "board.zip",
                       "url" => named_blob_file_path(zip.node_id, filename: "board.zip"),
                       "archive" => true,
                       "members" => fusion_zip_members } ],
                   layers_of(".gerber-stage")
    end

    # A ZIP IS ONLY A BOARD WHEN ITS CONTENTS SAY SO — `preview_kind` still answers from the NAME for
    # the whole vocabulary, and a zip of source is no more a board than a `.txt` is.
    test "a .zip of nothing relevant renders no gerber stage" do
      zip = write_gerber_zip!(name: "firmware.zip", body: gerber_zip("src/main.c" => "int main(){}"))

      get file_path(zip.node_id)
      assert_response :success
      assert_select ".gerber-stage", 0
    end

    test "a .txt file page does not render the gerber branch" do
      node = write_gerber!(name: "notes.txt", body: "plain")

      get file_path(node.node_id)
      assert_response :success
      assert_select ".gerber-stage", 0
    end

    # --- the private project panel -----------------------------------------------

    test "the project page groups a folder's Gerbers into one board and stacks them" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      set = write_gerber_set!(parent_node_id: dir.node_id)

      get project_path(project)
      assert_response :success
      assert_select "section.fabrication-panel h2", text: "Fabrication"
      assert_select ".fabrication-panel .fabrication-board", 1
      assert_select ".fabrication-board h3", text: "pcb"
      assert_select ".fabrication-board .schematics-list li", 3
      assert_select ".fabrication-board a[href=?]", file_path(set[:gtl].node_id)
      assert_select ".fabrication-board .badge", text: "top copper"
      assert_select ".fabrication-board .badge", text: "bottom copper"
      assert_select ".fabrication-board .badge", text: "drill"
      assert_equal %w[board.drl board.gbl board.gtl],
                   layers_of(".fabrication-board .gerber-stage").map { |l| l["name"] }
    end

    # TWO FOLDERS ARE TWO BOARDS. A project holds a main board and a daughterboard; stacking both
    # folders' copper together would render an image of nothing real.
    test "two folders of Gerbers are two boards, not one" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      main = gerber_dir!(name: "main", parent_node_id: folder.node_id)
      aux = gerber_dir!(name: "aux", parent_node_id: folder.node_id)
      write_gerber_set!(stem: "main", parent_node_id: main.node_id)
      write_gerber_set!(stem: "aux", parent_node_id: aux.node_id)

      get project_path(project)
      assert_response :success
      assert_select ".fabrication-panel .fabrication-board", 2
      assert_select ".fabrication-board h3", text: "aux"
      assert_select ".fabrication-board h3", text: "main"
      stages = css_select(".fabrication-board .gerber-stage")
      assert_equal [ %w[aux.drl aux.gbl aux.gtl], %w[main.drl main.gbl main.gtl] ],
                   stages.map { |s| JSON.parse(s["data-gerber-layers-value"]).map { |l| l["name"] } }
    end

    # THE LIST AND THE STACK ARE DIFFERENT LISTS, and this is the test that says so. A stray layer
    # left beside a job-driven export is LISTED (nothing goes invisible) and not STACKED.
    test "a job's stray sibling is listed but not stacked, and the board takes the job's name" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      write_gerber_set!(parent_node_id: dir.node_id)
      stray = write_gerber!(name: "old-revision.gtl", parent_node_id: dir.node_id)
      write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                    body: gerber_job("board.gtl", "board.gbl", "board.drl"))

      get project_path(project)
      assert_response :success
      # The job file and the stray are both in the LIST — five rows, not three.
      assert_select ".fabrication-board .schematics-list li", 5
      assert_select ".fabrication-board a[href=?]", file_path(stray.node_id)
      assert_select ".fabrication-board .badge", text: "job"
      assert_equal %w[board.drl board.gbl board.gtl],
                   layers_of(".fabrication-board .gerber-stage").map { |l| l["name"] }
      # THE JOB'S OWN STEM NAMES THE BOARD where there is a job — the folder's name only stands in
      # when there is not.
      assert_select ".fabrication-board h3", text: "board"
    end

    # A ZIPPED EXPORT IS ONE BOARD IN THE PANEL: one listed line (the zip, badge "archive") and a
    # viewer entry carrying the member paths — nobody has to unzip it into the library, which is the
    # report this whole feature came from.
    test "the project page lists a zipped export as a board of its own" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "Electronics", parent_node_id: folder.node_id)
      zip = write_gerber_zip!(parent_node_id: dir.node_id)

      get project_path(project)
      assert_response :success
      assert_select ".fabrication-panel .fabrication-board", 1
      assert_select ".fabrication-board h3", text: "board"
      assert_select ".fabrication-board .schematics-list li", 1
      assert_select ".fabrication-board a[href=?]", file_path(zip.node_id)
      assert_select ".fabrication-board .badge", text: "archive"
      assert_equal [ { "name" => "board.zip",
                       "url" => named_blob_file_path(zip.node_id, filename: "board.zip"),
                       "archive" => true,
                       "members" => fusion_zip_members } ],
                   layers_of(".fabrication-board .gerber-stage")
    end

    # A ZIP IS NEVER MERGED WITH THE LOOSE LAYERS BESIDE IT: an export is complete by construction,
    # so stacking a stray revision's copper on top of it would render an image of nothing real.
    test "a zip beside a loose set in one folder is two boards on the page" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      write_gerber_set!(parent_node_id: dir.node_id)
      write_gerber_zip!(name: "zed-export.zip", parent_node_id: dir.node_id)

      get project_path(project)
      assert_response :success
      assert_select ".fabrication-panel .fabrication-board", 2
      assert_select ".fabrication-board h3", text: "pcb"
      assert_select ".fabrication-board h3", text: "zed-export"
      stages = css_select(".fabrication-board .gerber-stage")
      assert_equal [ %w[board.drl board.gbl board.gtl], [ "zed-export.zip" ] ],
                   stages.map { |s| JSON.parse(s["data-gerber-layers-value"]).map { |l| l["name"] } }
      assert_equal [ nil, true ],
                   stages.map { |s| JSON.parse(s["data-gerber-layers-value"]).first["archive"] }
    end

    test "the project page shows no Fabrication panel when the folder holds no Gerbers" do
      project = @user.maker_projects.create!(name: "Driver")
      folder = make_project_folder!(@user, project)
      write_gerber!(name: "bracket.stl", parent_node_id: folder.node_id, body: "solid x")

      get project_path(project)
      assert_response :success
      assert_select ".fabrication-panel", 0
    end

    # --- the public project panel ------------------------------------------------

    test "the public page renders the same board through public file URLs" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "public")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      set = write_gerber_set!(parent_node_id: dir.node_id)
      reset!

      get public_project_path("gerber", project.slug)
      assert_response :success
      assert_select "section.fabrication-panel h2", text: "Fabrication"
      # The LIST links carry ?download=1 (a .gtl is not an inline-safe type, so the delivery concern
      # attaches it anyway and the URL should say so); the VIEWER's do not — it fetches and reads
      # the text, and a Content-Disposition nothing reads is noise.
      assert_select ".fabrication-board a[href=?]",
                    public_file_path("gerber", project.slug, set[:gtl].node_id, download: 1)
      assert_equal [ public_file_path("gerber", project.slug, set[:drl].node_id, filename: "board.drl"),
                     public_file_path("gerber", project.slug, set[:gbl].node_id, filename: "board.gbl"),
                     public_file_path("gerber", project.slug, set[:gtl].node_id, filename: "board.gtl") ],
                   layers_of(".fabrication-board .gerber-stage").map { |l| l["url"] }
    end

    # THE PUBLIC PANEL RENDERS THE ARCHIVE THROUGH THE PUBLIC FILE ROUTE — the same helper builds the
    # entry on both pages, so the two can only differ in how the URL is spelled.
    test "the public page renders a zipped export through the public file URL" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "public")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "Electronics", parent_node_id: folder.node_id)
      zip = write_gerber_zip!(parent_node_id: dir.node_id)
      reset!

      get public_project_path("gerber", project.slug)
      assert_response :success
      assert_select ".fabrication-board .badge", text: "archive"
      assert_equal [ { "name" => "board.zip",
                       "url" => public_file_path("gerber", project.slug, zip.node_id,
                                                 filename: "board.zip"),
                       "archive" => true,
                       "members" => fusion_zip_members } ],
                   layers_of(".fabrication-board .gerber-stage")
    end

    # THE ARCHIVE'S OWN URL IS REALLY DELIVERABLE, and it is the only fetch the viewer makes for a
    # zipped board — the members never have URLs of their own, because the browser unzips the bytes
    # this one call returns.
    test "the public viewer's archive URL actually serves the zip bytes" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "public")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "Electronics", parent_node_id: folder.node_id)
      # THE BYTES ARE CAPTURED ONCE AND COMPARED TO THEMSELVES. `fusion_zip` stamps `DOSTime.now`
      # (2-second granularity) into every header, so two builds that straddle an even second differ
      # at byte 10 — an `assert_equal fusion_zip, response.body` was red about one run in seven, and
      # for a reason that had nothing to do with the route (the review measured it).
      body = fusion_zip
      write_gerber_zip!(parent_node_id: dir.node_id, body:)
      reset!

      get public_project_path("gerber", project.slug)
      entry = layers_of(".fabrication-board .gerber-stage").first

      get entry["url"]
      assert_response :success
      assert_equal body, response.body.b
    end

    # EVERY URL AN UNLISTED PAGE RENDERS CARRIES THE TOKEN — including the ones only JavaScript ever
    # fetches. Without it the viewer's own fetches 404 and the board never paints, while the page
    # around it looks perfectly fine.
    test "an unlisted page's viewer URLs carry the token" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "unlisted")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      write_gerber_set!(parent_node_id: dir.node_id)
      # THE ARCHIVE ENTRY IS BUILT BY A DIFFERENT BRANCH of the same helper, so it needs its own
      # sample here: a zipped board whose one URL lost the token would leave the panel rendered and
      # the board blank, with nothing on the page saying why.
      write_gerber_zip!(name: "zed-export.zip", parent_node_id: dir.node_id)
      token = project.reload.unlisted_token
      reset!

      get public_project_path("gerber", project.slug, k: token)
      assert_response :success
      urls = css_select(".fabrication-board .gerber-stage").flat_map { |s|
        JSON.parse(s["data-gerber-layers-value"]).map { |l| l["url"] }
      } + css_select(".fabrication-board .schematics-list a").map { |a| a["href"] }
      assert_equal 8, urls.size
      urls.each { |url| assert_includes url, "k=#{token}", url }
    end

    # THE VIEWER'S OWN URLS ARE REALLY DELIVERABLE, not merely well-formed. `permits?` answers by
    # ancestry for a file beneath the project folder, and a link the page renders that then 404s is
    # the exact pair Maker::PublicProject exists to prevent.
    test "the public viewer's layer URLs actually serve the bytes" do
      project = @user.maker_projects.create!(name: "Driver", visibility: "public")
      folder = make_project_folder!(@user, project)
      dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
      write_gerber_set!(parent_node_id: dir.node_id)
      reset!

      get public_project_path("gerber", project.slug)
      layers_of(".fabrication-board .gerber-stage").each do |layer|
        get layer["url"]
        assert_response :success, layer["url"]
        assert_predicate response.body, :present?
      end
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
