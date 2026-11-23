require "test_helper"

module Web
  # THE MATERIAL ESTIMATE PAGE (spec 2026-11-22-material-estimate-design.md, Part 2), driven through
  # real requests. What only a browser can see — the debounced re-figure, the upload on change — is
  # test/system/material_estimate_test.rb's.
  class MaterialEstimateTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    # An explicit Accept rather than `as: :turbo_stream`, so a multipart upload body is left exactly
    # as Rack::Test builds it.
    STREAM = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "material-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      ActionController::Base.cache_store.clear
    end

    def upload(name) = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files", name), "application/octet-stream")

    def stock(width: "200", height: "100", gap: "0", unit: "mm", rotate: "0") = { sheet_width: width, sheet_height: height, gap:, unit:, rotate: }

    def part(name:, width:, height:, qty: "1", node_id: "", page: "", reason: "") = { name:, width:, height:, qty:, node_id:, page:, reason: }

    test "the page is a signed-in built-in tool, empty, with the default stock" do
      get tools_material_path
      assert_response :success
      assert_select "h1", text: "Material estimate"
      assert_select "form#material-form[action=?][data-controller=?]", tools_material_path, "material-estimate"
      assert_select "#material-parts p.material-empty"
      assert_select "input#sheet_width[value=?]", "300"
      assert_select "select#unit option[selected][value=?]", "mm"
      assert_select "input#rotate[checked]"
      assert_select "button[formaction=?]", tools_material_measure_path
      # THE RENDERED NAMES ARE WHAT THE CONTROLLER READS: every other test here POSTs a Ruby hash,
      # which bypasses the form entirely (§14d).
      Tools::MaterialsController::STOCK_FIELDS.each { |field| assert_select "#material-form [name=?]", field.to_s }
      assert_select "#material-form input[type=file][name=?]", "uploads[]"
      %w[add_folder_id add_file_id].each { |field| assert_select "#material-form input[type=hidden][name=?]", field }

      reset!
      get tools_material_path
      assert_response :redirect
    end

    # WITHOUT JAVASCRIPT THERE IS NO X-CSRF-Token HEADER, so the form's own token must be good for
    # the Measure button's `formaction` too. Per-form tokens bind a token to the form's action, which
    # refused Measure with a 422; the test env turns forgery protection off, so it is turned on here.
    test "the form's token is accepted by the Measure button's action as well as the form's own" do
      ActionController::Base.allow_forgery_protection = true
      get tools_material_path
      token = css_select("#material-form input[name=authenticity_token]").first["value"]

      post tools_material_measure_path, params: { authenticity_token: token, uploads: [ upload("plate.svg") ], **stock }
      assert_response :success
      assert_select ".material-parts-table tbody tr", count: 1

      post tools_material_path, params: { authenticity_token: token, **stock }
      assert_response :success
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    # ENTER IN ANY FIELD PRESSES THE FORM'S FIRST SUBMIT BUTTON (HTML's implicit submission). It must
    # be one that re-figures, never Measure uploads, which posts to the rate-limited upload action.
    test "the form's first submit button re-figures, so Enter never posts to the upload action" do
      get tools_material_path
      first = css_select("#material-form button").find { |b| b["type"].in?([ nil, "submit" ]) }
      assert_nil first["formaction"], "the default button must post to the form's own action"
      assert first.key?("hidden"), "and it is not a second visible Update button"
    end

    # THE ROUTE BEATS THE ADDON WILDCARD (Task 7's routes): `tools/:key` would answer this with
    # Tools::AddonsController, a 404 for an unknown addon.
    test "/tools/material is the built-in page, not an addon lookup" do
      get "/tools/material"
      assert_equal "tools/materials", controller.controller_path
    end

    test "uploads are measured and nothing of them is kept" do
      # An Array of lambdas, never one lambda returning an Array: assert_difference adds the expected
      # difference to each value, and Array + 0 raises.
      assert_no_difference [ -> { Node.count }, -> { Maker::Preview.count }, -> { ActiveStorage::Blob.count } ] do
        post tools_material_measure_path, params: { uploads: [ upload("plate.svg"), upload("plate.dxf") ], **stock },
                                          headers: STREAM
      end
      assert_response :success
      assert_empty Dir.children(@root), "an upload reached the library"
      assert_select "turbo-stream[action=replace][target=material-parts]", 1
      assert_select "turbo-stream[action=replace][target=material-results]", 1
      assert_includes response.body, "plate.svg"
      assert_includes response.body, "plate.dxf"
      assert_includes response.body, "80 × 40"
      assert_includes response.body, %(name="parts[1][width]" value="80.0")
    end

    test "a quantity change re-figures the results and leaves the parts list alone" do
      # A filename is user input, and the sheet drawing prints it twice (its <title> and its label).
      post tools_material_path, params: { parts: { "0" => part(name: "<b>x</b>.svg", width: "100", height: "50", qty: "5") }, **stock },
                                headers: STREAM
      assert_response :success
      assert_select "turbo-stream[action=replace][target=material-parts]", 0
      assert_select "turbo-stream[action=replace][target=material-results]", 1
      assert_includes response.body, %(<dd class="material-sheet-count">2 × 200 × 100 mm</dd>)
      assert_includes response.body, "250 cm² · 38.8 in²"
      assert_includes response.body, "63%"
      assert_includes response.body, "&lt;b&gt;x&lt;/b&gt;.svg"
      refute_includes response.body, "<b>x</b>", "a part's name reached the sheet drawing unescaped"
    end

    test "remove takes one row out and replaces the list" do
      post tools_material_path, params: { remove: "0", parts: { "0" => part(name: "gone.svg", width: "10", height: "10"),
                                                                "1" => part(name: "kept.svg", width: "10", height: "10") }, **stock },
                                headers: STREAM
      assert_select "turbo-stream[action=replace][target=material-parts]", 1
      refute_includes response.body, "gone.svg"
      assert_includes response.body, "kept.svg"
    end

    test "a folder of the user's own adds its files; another user's adds nothing and says so" do
      laser = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      plate = create_node!(@user, node_id: SecureRandom.uuid, name: "plate.svg", kind: "file", parent_node_id: laser.node_id,
                                  content_hash: SecureRandom.hex(8))
      @root.join(plate.storage_path).binwrite(File.binread(Rails.root.join("test/fixtures/files/plate.svg")))

      post tools_material_path, params: { add_folder_id: laser.node_id, **stock }, headers: STREAM
      assert_includes response.body, %(href="#{file_path(plate.node_id)}")

      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir", mtime: 1, size: 0)
      post tools_material_path, params: { add_folder_id: theirs.node_id, **stock }, headers: STREAM
      assert_includes response.body, "Found no such folder."
    end

    # ---- a folder inside a project (2026-11-23) --------------------------------------------------

    def dir!(name, parent: nil) = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent&.node_id)

    def place!(name, parent:)
      node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent.node_id,
                                 content_hash: SecureRandom.hex(8))
      @root.join(node.storage_path).binwrite(File.binread(Rails.root.join("test/fixtures/files/plate.svg")))
      node
    end

    # Desk Lamp's folder holds laser/cut.svg and paper/sketch.svg, both attached to the project.
    def desk_lamp!
      lamp = @user.maker_projects.create!(name: "Desk Lamp")
      folder = dir!("desk-lamp", parent: dir!("Projects"))
      lamp.update_column(:folder_node_id, folder.node_id)
      laser = dir!("laser", parent: folder)
      files = { cut: place!("cut.svg", parent: laser), sketch: place!("sketch.svg", parent: dir!("paper", parent: folder)) }
      files.each_value { |node| @user.maker_file_attachments.create!(attachable: lamp, node_id: node.node_id) }
      [ lamp, folder, laser, files ]
    end

    # THE MENU TELLS THE BROWSER WHICH FOLDER TO OPEN THE CHOOSER IN, and only a LIVE one: a project
    # with no folder, or with its folder in the Trash, carries none and adds whole at once.
    test "the project menu carries each project's live folder, for the chooser to open inside" do
      lamp, folder, = desk_lamp!
      @user.maker_projects.create!(name: "No Folder")
      trashed = @user.maker_projects.create!(name: "Trashed Folder")
      gone = dir!("trashed-folder")
      gone.update_columns(deleted: true)
      trashed.update_column(:folder_node_id, gone.node_id)
      @user.maker_projects.create!(name: "Put Away", status: "archived")

      get tools_material_path
      assert_response :success
      assert_select "#material-parts select[name=add_project_id][data-action=?][data-children-url=?]",
                    "change->material-estimate#addProject", library_children_path
      options = css_select("select[name=add_project_id] option").reject { |o| o["value"].blank? }
      assert_equal [ [ "Desk Lamp", lamp.id.to_s, folder.node_id ], [ "No Folder", nil, nil ], [ "Trashed Folder", nil, nil ] ],
                   options.map { |o| [ o.text, (o["value"] if o["data-folder-id"]), o["data-folder-id"] ] }
      assert_select "#material-parts input[type=hidden][name=add_project_folder_id][data-material-estimate-target=projectFolder]", 1
    end

    test "a folder chosen inside a project adds that folder's files instead of the whole project" do
      lamp, _, laser, files = desk_lamp!

      post tools_material_path, params: { add_project_id: lamp.id, **stock }, headers: STREAM
      files.each_value { |node| assert_includes response.body, %(href="#{file_path(node.node_id)}") }

      post tools_material_path, params: { add_project_id: lamp.id, add_project_folder_id: laser.node_id, **stock }, headers: STREAM
      assert_includes response.body, %(href="#{file_path(files[:cut].node_id)}")
      refute_includes response.body, %(href="#{file_path(files[:sketch].node_id)}")
      refute_includes response.body, "parts[1]", "the folder replaces the project; it is not added beside it"
    end

    # A FOLDER THAT IS NOT THE USER'S answers like any missing folder, and the project is NOT added
    # whole in its place: the maker chose a folder, and the note says it was not found.
    test "a project folder that is not the user's adds nothing and says so" do
      lamp, = desk_lamp!
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir", mtime: 1, size: 0)

      post tools_material_path, params: { add_project_id: lamp.id, add_project_folder_id: theirs.node_id, **stock }, headers: STREAM
      assert_includes response.body, "Found no such folder."
      refute_includes response.body, "parts[0]"
    end

    # THE DEBT template_hygiene_test.rb's UNSWEPT_TEMPLATES names: update.turbo_stream and _sheet
    # render only for a POST, which its GET sweep cannot issue. A remove replaces the parts list, so
    # this one stream renders all four templates it touches.
    test "the estimate's streams leak no template comment" do
      needles = [ "ONE SHEET, DRAWN IN MM", "THE PARTS LIST", "THE RESULTS, replaced" ]
      sources = Dir.glob(Rails.root.join("app/views/tools/materials/*.erb")).map { |f| File.read(f, encoding: "UTF-8") }
      needles.each { |needle| assert sources.any? { |src| src.include?(needle) }, "#{needle.inspect} is in no template, so it can never fire" }

      post tools_material_path, params: { remove: "1", parts: { "0" => part(name: "a.svg", width: "100", height: "50"),
                                                                "1" => part(name: "b.svg", width: "10", height: "10") }, **stock },
                                headers: STREAM
      assert_response :success
      assert_includes response.body, %(<figure class="material-sheet">), "the stream drew no sheet, so _sheet went unswept"
      [ "<%", "%>", "§", *needles ].each do |leak|
        assert_not_includes response.body, leak, "the estimate's stream rendered #{leak.inspect}"
      end
    end

    test "a forged hidden size is refused on the row, not packed" do
      post tools_material_path, params: { parts: { "0" => part(name: "x.svg", width: "-5", height: "10") }, **stock },
                                headers: STREAM
      assert_includes response.body, "Nothing to lay out yet."
    end

    test "without JavaScript the same request renders the whole page" do
      post tools_material_path, params: { parts: { "0" => part(name: "a.svg", width: "100", height: "50", qty: "5") }, **stock }
      assert_response :success
      assert_select "h1", text: "Material estimate"
      assert_select "dd.material-sheet-count", text: "2 × 200 × 100 mm"
      # The row carries every field the next request rebuilds it from, under the permitted names.
      Tools::MaterialsController::PART_FIELDS.each { |field| assert_select "#material-parts [name=?]", "parts[0][#{field}]" }
      assert_select "input[type=number][name=?][value=?]", "parts[0][qty]", "5"
    end

    test "uploads are rate-limited per user, and the refusal keeps the list" do
      Tools::MaterialsController::UPLOADS_PER_MINUTE.times do
        post tools_material_measure_path, params: { uploads: [ upload("square.svg") ], **stock }, headers: STREAM
        assert_response :success
      end
      post tools_material_measure_path, params: { uploads: [ upload("square.svg") ], **stock,
                                                  parts: { "0" => part(name: "kept.svg", width: "10", height: "10") } },
                                        headers: STREAM
      assert_response :too_many_requests
      assert_includes response.body, "Paused uploads"
    end

    # Re-figuring is arithmetic under Estimate's caps, so only the upload door is limited: a person
    # typing quantities must never meet the upload limit's refusal.
    test "re-figuring is not rate-limited" do
      (Tools::MaterialsController::UPLOADS_PER_MINUTE + 1).times do
        post tools_material_path, params: { parts: { "0" => part(name: "a.svg", width: "10", height: "10") }, **stock },
                                  headers: STREAM
        assert_response :success
      end
    end

    test "a pinned Material estimate lights its rail link on its own page" do
      post tools_pin_path("material")
      get tools_material_path
      assert_select "aside.rail a.rail-tool-pin[href=?][aria-current=page]", tools_material_path
    end
  end
end
