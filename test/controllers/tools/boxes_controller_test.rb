require "test_helper"
require_relative "../../support/fake_boxes"

module Tools
  class BoxesControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "boxes@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      BoxesClient.stub = FakeBoxes.new
      Storage::ChunkStore.reset!
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end
    teardown do
      BoxesClient.reset!
      FileLayer.reset!
    end

    test "index tiles show the generator's short name (key), not its descriptive title" do
      get tools_boxes_path
      assert_response :success
      assert_select ".addon-card .addon-title", text: "ABox" # short name on the tile
      assert_select ".addon-card", text: /Simple box/, count: 0 # descriptive title lives on the editor now
    end

    test "index groups generators under their real boxes.py ui_group headings" do
      get tools_boxes_path
      assert_response :success
      assert_select ".box-group-title", text: "Box"
      assert_select ".box-group-title", text: "Tray"
      assert_select ".addon-card[data-boxfilter-target='card']", minimum: 2
      assert_select "input.box-search"
    end

    test "every index section is a collapsible details the table of contents can link to" do
      get tools_boxes_path
      assert_response :success
      # The folding is markup, not script: a <details> per section, so the page collapses with JS off.
      assert_select "details.box-group[id='box-section-box'] > summary .box-group-title", text: "Box"
      assert_select "details.box-group[id='box-section-tray'] > summary .box-group-title", text: "Tray"
      assert_select "details.box-group[id='box-section-holes'] > summary .box-group-title", text: "Holes"
      # …and every TOC entry points at a section id that EXISTS. A href naming a missing id is a dead
      # link that still looks fine in the markup, which is precisely what a count-only assertion misses.
      links = css_select("nav.box-toc a[data-boxsections-target='link']").map { |a| a["href"] }
      assert_equal %w[#box-section-box #box-section-holes #box-section-tray], links.sort
      ids = css_select("details.box-group").map { |d| d["id"] }
      links.each { |href| assert_includes ids, href.delete_prefix("#"), "TOC links to a section that isn't on the page" }
    end

    test "the saved rail groups boxes by section then by box type, both folded shut" do
      @user.maker_addon_states.create!(addon_key: "boxes", name: "Deep Box",
                                       data: { "generator" => "ABox", "params" => {} })
      @user.maker_addon_states.create!(addon_key: "boxes", name: "Parts Tray",
                                       data: { "generator" => "TypeTray", "params" => {} })

      get tools_boxes_path
      assert_response :success
      section = css_select("aside.box-saved-rail details.box-saved-section#saved-section-box").first
      assert section, "expected a Box section in the saved rail"
      assert_nil section["open"], "the saved rail's sections must start collapsed"
      type = css_select("aside.box-saved-rail details.box-saved-type#saved-type-box-abox").first
      assert type, "expected the ABox type to nest inside the Box section"
      assert_nil type["open"], "the saved rail's box types must start collapsed"
      # nesting is the point — the type sits INSIDE its section, not beside it
      assert_select "details.box-saved-section#saved-section-box details.box-saved-type .box-saved-link",
                    text: "Deep Box"
      assert_select "details.box-saved-section#saved-section-tray .box-saved-link", text: "Parts Tray"
    end

    # A saved box outlives the sidecar's generator list (a fork bump can drop a generator). Its file is
    # still in the user's library, so the rail must still show it — filed under "Other", not dropped.
    test "a saved box whose generator the sidecar no longer offers still appears, under Other" do
      @user.maker_addon_states.create!(addon_key: "boxes", name: "Ghost Box",
                                       data: { "generator" => "RetiredBox", "params" => {} })
      get tools_boxes_path
      assert_response :success
      assert_select "details.box-saved-section#saved-section-other .box-saved-link", text: "Ghost Box"
    end

    test "index tiles show the generator's sample photo via the internal proxy (JS fallback on 404)" do
      get tools_boxes_path
      assert_response :success
      assert_select "a.addon-card img.addon-thumb[data-controller='thumbfallback']"
      assert_select "img.addon-thumb[src=?]", "/tools/boxes/thumb/ABox"
      assert_select "img.addon-thumb[src*='githubusercontent']", count: 0 # self-hosted, no external host
    end

    test "thumb proxies a generator's sample photo from the sidecar, 404 when there is none" do
      get thumb_tools_boxes_path("ABox")
      assert_response :success
      assert_equal "image/jpeg", response.media_type
      assert response.body.bytesize.positive?

      get thumb_tools_boxes_path("TypeTray") # FakeBoxes has no sample for this one -> nil -> 404
      assert_response :not_found
    end

    test "EVERY param group folds: basics open, advanced closed, all of them collapsible" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      basic = css_select("details.param-group#param-group-abox-settings").first
      assert basic, "a basic group must be a <details> too, so it can be folded away once it's set"
      assert_not_nil basic["open"], "a basic group starts open"
      assert_select "details.param-group#param-group-abox-settings > summary .param-group-title",
                    text: "ABox Settings"
      assert_select "details.param-group input[name=?]", "params[x]"

      advanced = css_select("details.param-group-adv#param-group-settings-for-finger-joints").first
      assert advanced, "an advanced group keeps its own boxed-off look"
      assert_nil advanced["open"], "an advanced group starts collapsed"
      assert_select "details.param-group-adv > summary .param-group-title", text: "Settings for Finger Joints"
      # Collapsed or not, the fields stay in the DOM — that is what keeps them submitted.
      assert_select "details.param-group-adv select[name=?]", "params[FingerJoint_style]"

      # …and the collapse-all control drives the same controller the sections are targets of.
      assert_select ".box-editor[data-controller~='boxsections'] button[data-action='boxsections#toggleAll']"
    end

    test "new headings the generator's short name (key) with its title as a description" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".page-head h1", text: "ABox"          # the short name is the heading
      assert_select ".page-subtitle", text: "Simple box"    # the descriptive title moved here
    end

    test "new renders a dynamic form from the generator's params" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "input[name=?]", "params[x]"
      assert_select "input[name=?]", "params[y]"
    end

    # TrayLayout's `layout` is column-aligned ASCII art. An <input type="text"> runs HTML's value
    # sanitization algorithm, which STRIPS line breaks — so the art reached the sidecar as one line
    # and boxes.py answered "traylayout requires --layout, --input, or implementation of
    # generate_layout". A textarea is the only control that carries the newlines.
    test "a multiline param renders as a textarea, never a line-stripping text input" do
      get new_tools_box_path(generator: "TrayLayout")
      assert_response :success
      assert_select "textarea[name=?]", "params[layout]"
      assert_select "input[type=text][name=?]", "params[layout]", count: 0
      # its non-multiline siblings are untouched
      assert_select "input[type=text][name=?]", "params[sx]"
    end

    test "the layout textarea carries the seeded art with its line breaks intact" do
      get new_tools_box_path(generator: "TrayLayout")
      assert_response :success
      art = css_select("textarea[name='params[layout]']").first.text
      # Assert the WIRE, not the parsed round-trip — Nokogiri does not model the HTML parser's
      # "swallow one newline after <textarea>" rule, so a round-trip assertion passes whether the
      # spare newline is there, missing, or doubled (all three verified by mutation).
      # EXACTLY one: none eats the first line of any layout that opens on a blank one (FrontPanel's
      # default does), and two leaves one behind, growing a stray blank first line on every field.
      assert_match %r{<textarea[^>]*name="params\[layout\]"[^>]*>\n(?!\n)}, response.body,
                   "the textarea must open with exactly one spare newline for the parser to eat"
      assert_equal FakeBoxes::TRAY_LAYOUT, art.delete_prefix("\n")
      assert_operator art.lines.size, :>, 4, "the art collapsed to a single line"
      assert_includes art, "+-+-+-+"
    end

    test "a layout loaded from a saved box is flagged so the sync controller leaves it alone" do
      mine = FakeBoxes::TRAY_LAYOUT.sub("| | | | 50.0mm", "| |   | 50.0mm") # a wall removed by hand
      get new_tools_box_path(generator: "TrayLayout", params: { params: { layout: mine } })
      assert_response :success
      assert_select "textarea[name='params[layout]'][data-prefilled=?]", "true"
      assert_equal mine, css_select("textarea[name='params[layout]']").first.text.delete_prefix("\n")

      get new_tools_box_path(generator: "TrayLayout") # unprefilled -> the flag is absent
      assert_select "textarea[name='params[layout]'][data-prefilled]", count: 0
    end

    test "the editor form drives the layout/sx/sy sync controller" do
      get new_tools_box_path(generator: "TrayLayout")
      assert_response :success
      assert_select "form[data-controller~=traylayout] textarea[name=?]", "params[layout]"
    end

    test "new renders the two-column editor with a params grid and a preview column" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-editor > form .box-params input[name=?]", "params[x]"
      assert_select ".box-editor > aside.box-side .box-preview img[data-boxpreview-target='image']"
    end

    test "Preview and Save ride ABOVE the params, not below sixty fields of them" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-actions button[data-action='boxpreview#preview']"
      assert_select ".box-actions button[type=submit]", text: "Save to library"
      # DOM ORDER is the whole claim, and it is the half a plain "the button exists" assertion can't
      # see: both buttons existed before this change, parked under the form.
      kids = css_select(".box-editor > form").first.element_children.map { |e| e["class"].to_s }
      actions = kids.index { |c| c.include?("box-actions") }
      first_group = kids.index { |c| c.include?("param-group") }
      assert actions && first_group, "expected an actions block and at least one param group"
      assert_operator actions, :<, first_group, "the actions block must precede the param groups"
    end

    test "the preview panel renders the defaults on load and has somewhere to report a failure" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      # No `data-action` wires the first render: the controller fires it on connect, which is what
      # makes an untouched generator show its default box instead of an empty panel.
      assert_select ".box-editor[data-controller~='boxpreview'][data-boxpreview-url-value=?]",
                    preview_tools_boxes_path
      assert_select "form[data-boxpreview-target='form']"
      assert_select ".box-preview [data-boxpreview-target='status'][aria-live='polite']"
    end

    test "preview returns a rasterized PNG of the generated SVG" do
      post preview_tools_boxes_path, params: { generator: "ABox", params: { x: 120, y: 60 } }
      assert_response :success
      assert_equal "image/png", response.media_type if Maker::Previews::SvgRasterizer.available?
    end

    test "create saves the state + a tied bundle of ONE file — the params live in the DB" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_boxes_path, params: { name: "My Box", generator: "ABox", params: { x: 120, y: 60 } }
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal %w[output], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }

      # Asserted at the LIBRARY level, not just on the join rows: the FILE is what was removed, and a
      # `.params.json` written as an untied node would still pass the roles check above.
      assert_empty @user.nodes.present.where("name LIKE ?", "%.params.json"),
                   "no .params.json may be written into the library"

      # …and the params really are recorded, in the DB.
      assert_equal({ "generator" => "ABox", "params" => { "x" => "120", "y" => "60" } }, state.data)
      assert_redirected_to tools_box_path(state)
    end

    test "new offers a folder picker: the library root plus existing folders" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "select[name='parent_node_id'] option[value='']" # root, the default
      assert_select "select[name='parent_node_id'] option", text: %r{/Projects}
    end

    # Spy on LibraryOutput.write (define_singleton_method — the repo's mocking idiom, e.g.
    # chunk_test.rb) so these assert the CONTROLLER's parent-selection wiring without depending on
    # any one backend's write mechanics -> they pass identically on chunk/share/s3.
    test "create saves the bundle into the chosen folder" do
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_boxes_path,
             params: { name: "Boxed", generator: "ABox", params: { x: 1, y: 2 }, parent_node_id: folder.node_id }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_equal folder.node_id, captured
    end

    test "create ignores a parent_node_id that is not the user's own live folder (falls back to root)" do
      other = User.create!(email: "other-boxes@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_boxes_path,
             params: { name: "Boxed", generator: "ABox", params: { x: 1, y: 2 }, parent_node_id: foreign.node_id }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_nil captured
    end

    test "show reopens a saved box with its params" do
      post tools_boxes_path, params: { name: "Reopen Me", generator: "ABox", params: { x: 77, y: 33 } }
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      get tools_box_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
    end

    test "show lists the params and offers the JSON download (they are not a file any more)" do
      state = @user.maker_addon_states.create!(
        addon_key: "boxes", name: "Multi Tray",
        # A MULTILINE value: boxes' TrayLayout/FrontPanel/NightLightBox section params are
        # newline-separated, and they are why the value cell must not collapse whitespace.
        data: { "generator" => "ABox", "params" => { "x" => "120", "sx" => "50 60\n70 80" } }
      )
      get tools_box_path(state)
      assert_response :success
      assert_select "section.addon-params dl.meta dt", text: "x"
      assert_select "section.addon-params dl.meta dd", text: "120"
      assert_select "section.addon-params a[href=?]", tools_addon_params_path(state)
      # The newline must survive into the markup. The `white-space: pre-wrap` that makes it RENDER as
      # two lines is CSS and cannot be asserted here; this guards the half that can be — that the
      # view never squishes or truncates the value.
      assert_includes response.body, "50 60\n70 80"
    end

    test "new lists prior boxes for this generator only, newest first" do
      post tools_boxes_path, params: { name: "Older ABox", generator: "ABox", params: { x: 1, y: 2 } }
      post tools_boxes_path, params: { name: "Newer ABox", generator: "ABox", params: { x: 3, y: 4 } }
      post tools_boxes_path, params: { name: "A Tray",     generator: "TypeTray", params: { x: 5 } }

      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior", text: /Newer ABox/
      assert_select ".box-prior", text: /Older ABox/
      assert_select ".box-prior", text: /A Tray/, count: 0
      assert response.body.index("Newer ABox") < response.body.index("Older ABox"),
             "newer box should render before older"
      # the rail wires each prior box to the shared thumbnails poller (reuse, not a new endpoint)
      assert_select ".box-prior[data-controller='thumbs']"
      assert_select ".box-prior-item[data-thumbs-target='cell'][data-node-id]", minimum: 2
    end

    test "new omits the history rail when this generator has no saved boxes" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior", count: 0
      assert_select ".box-prior-hint", text: /No saved boxes/
    end

    test "a prior box's Load link nests params under params[] so the editor actually prefills" do
      post tools_boxes_path, params: { name: "Loadable", generator: "ABox", params: { x: 999, y: 7 } }

      get new_tools_box_path(generator: "ABox")
      assert_response :success
      href = css_select(".box-prior a").find { |a| a.text.strip == "Load" }&.[]("href")
      assert href, "expected a Load link in the rail"
      # WIRE FORMAT, asserted deliberately: params must be NESTED (params[x]=999), not flattened
      # (x=999). `:params` is a reserved url_for option that appends its hash to the query string, so
      # the flattened form is silently ignored by `new` (which reads params[:params]) -> no prefill.
      # Comparing against new_tools_box_path(params:) would reproduce the SAME bug on both sides and
      # pass vacuously (that was the original test's flaw).
      assert_includes href, "params%5Bx%5D=999"
      assert_includes href, "params%5By%5D=7"

      # END-TO-END: following the Load link actually prefills the form (the behavior that broke).
      get href
      assert_response :success
      assert_select "input[name='params[x]'][value=?]", "999"
    end

    test "the param form renders a boxes.py manual link as a compact link, not raw markdown" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      # y's help carries a `[🛈](…usermanual.html#y)` manual link; it must become a compact
      # <a class="box-help">, and the raw glyph / URL must NOT appear as inline label text.
      assert_select "a.box-help[href=?]", "https://florianfesti.github.io/boxes/html/usermanual.html#y"
      assert_select ".box-field-label", text: /🛈/, count: 0
      assert_select ".box-field-label", text: /usermanual\.html/, count: 0
    end

    test "new pre-selects the current project's folder in the save picker" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      get new_tools_box_path(generator: "ABox") # #new must lazily ensure the folder for it to be an option
      assert_response :success
      folder = project.ensure_library_folder!(@user) # idempotent — returns the folder #new just created
      assert_select "select[name='parent_node_id'] option[selected='selected'][value=?]", folder.node_id
    end

    test "create attaches the output file to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 1 do
        post tools_boxes_path, params: { name: "Cur Box", generator: "ABox", params: { x: 1, y: 2 },
                                         parent_node_id: folder.node_id }
      end
      # the attached node lives under the project folder
      project.file_attachments.each do |att|
        assert_equal folder.node_id, @user.nodes.find_by(node_id: att.node_id).parent_node_id
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal state.files.map(&:node_id).sort, project.file_attachments.pluck(:node_id).sort,
                   "the one output file (svg) must be the attached node"
    end

    test "create attaches nothing when no project is current" do
      @user.maker_projects.create!(name: "Desk Lamp") # exists but not current
      assert_no_difference "Maker::FileAttachment.count" do
        post tools_boxes_path, params: { name: "Loose Box", generator: "ABox", params: { x: 1, y: 2 } }
      end
    end

    # THE RACE TASK 9a's FOLLOW-UP CLOSES HERE TOO, AND THE FAILURE SHAPE IS DIFFERENT FROM ITS
    # THREE SIBLINGS (Maker::AttachToProject#call, Models::AttachmentsController#create,
    # Projects::EntryPhotosController#create). CurrentProject#attach_addon_files_to_current_project
    # already wraps its per-file loop in ActiveRecord::Base.transaction — deliberately, so a
    # mid-loop failure leaves no PARTIAL set, and this fix does not remove that — and the whole
    # method in a broad `rescue StandardError` (best-effort: the tool's OUTPUT is already saved, so
    # a failed attach must never turn a successful save into an error). Before this fix, a race on
    # ANY ONE of the addon's output files raised ActiveRecord::RecordNotUnique from a bare create!,
    # which the transaction turned into "roll back EVERY file in this batch" and the outer rescue
    # turned into "log a warning and attach nothing" — converting "one file raced, the rest are
    # fine" into "none of them attached", SILENTLY, which is the failure shape this codebase most
    # dislikes (no error page, and the addon's own save already succeeded, so nothing else signals
    # it either). Fixed the same way as the other three: create_or_find_by! per file, so a race on
    # one file is absorbed inside its OWN savepoint without taking the surrounding transaction — or
    # the other files from the same save — down with it.
    #
    # with_concurrent_file_attachment races whichever file create_or_find_by! is called on FIRST —
    # this test does not know or care which of the two output files that is, only that BOTH must
    # still be attached afterward.
    test "a race on one output file does not lose the other from the same save" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }

      with_concurrent_file_attachment do
        assert_nothing_raised do
          post tools_boxes_path, params: { name: "Raced Box", generator: "ABox", params: { x: 1, y: 2 },
                                           parent_node_id: folder.node_id }
        end
      end

      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal state.files.map(&:node_id).sort, project.file_attachments.pluck(:node_id).sort,
                   "BOTH output files must be attached — a race on one must not cost the other"
    end
  end
end
