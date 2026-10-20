require "test_helper"

module Web
  # CONTENT BLOCKS, SERVER HALF (2026-09-09; spec §5, §6): what both pages render for each kind,
  # what Save writes in one transaction, the preview helper, and the editor's markup. The browser's
  # half is test/system/page_blocks_test.rb.
  class ProjectBlocksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "blocks-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp.")
      @folder = project_folder_rows!(@user, @project)
      @photos = dir!("photos", @folder.node_id)
      @side = file!("side.jpg", @photos.node_id)
      @front = file!("front.png", @photos.node_id)
    end

    def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
    def block!(**attrs) = @project.blocks.create!(user: @user, **attrs)
    def bkey(block) = block.layout_key

    # --- rendering ---------------------------------------------------------------------------------

    test "each kind renders in its slot at its default width, Markdown sanitised" do
      text = block!(kind: "text", heading: "Why", body: "A **shade**.\n\n<script>alert(1)</script>\n\n[bom](#bom)")
      link = block!(kind: "link", heading: "Printables", url: "https://www.printables.com/model/1", line: "Sliced.")
      image = block!(kind: "image", node_id: @side.node_id, caption: "Side on.")

      get project_path(@project)

      assert_select "div.panel-slot.panel--full > section.block-panel.block--text[id=?]", bkey(text) do
        assert_select "h2", text: "Why"
        assert_select ".markdown strong", text: "shade"
        assert_select "script", count: 0
      end
      # THE SANITISER'S OWN CLAIM, ASSERTED ON THE WHOLE DOCUMENT rather than only as an absent
      # ELEMENT inside the block above: `assert_select "script"` sees an element, so a body rendered
      # through kramdown WITHOUT Maker::Markdown's sanitiser fails it — but a `<script>` that
      # survived as escaped TEXT would be a text node no assert_select in this suite can see (the
      # shape §14d records for a leaked ERB comment). Maker::Markdown removes the executable element
      # WITH its content, so the payload is gone from the bytes, not merely from the DOM.
      refute_includes response.body, "alert(1)", "the block's script survived into the page"
      assert_select "div.panel-slot.panel--half > section.block-panel.block--link[id=?]", bkey(link) do
        assert_select "a.block-link-card[href=?][rel=noopener]", "https://www.printables.com/model/1"
        assert_select ".block-link-title", text: "Printables"
        assert_select ".block-link-line", text: "Sliced."
        assert_select ".block-link-host", text: "www.printables.com"
      end
      assert_select "div.panel-slot.panel--full > section.block-panel.block--image[id=?]", bkey(image) do
        assert_select "figure a[href=?] img[src=?]", file_path(@side.node_id), blob_file_path(@side.node_id)
        assert_select "figcaption", text: "Side on."
      end
      assert_select "div.panel-slot[data-key]", { count: 0 }, "no chrome on the normal page"
    end

    test "a hidden block and an image block whose file is gone render no slot" do
      text = block!(kind: "text", body: "x")
      block!(kind: "image", node_id: SecureRandom.uuid)
      @project.update!(panels: { "hidden" => [ bkey(text) ] })

      get project_path(@project)
      assert_select "section.block-panel", count: 0
      # EVERY SLOT HOLDS A PANEL, and this is the assertion with weight: the two counts above cannot
      # see an EMPTY slot, which still occupies a grid cell (the same argument
      # project_layout_editor_test.rb records for a panel that renders nothing).
      slots = css_select("div.project-panels > div.panel-slot")
      assert_equal slots.size, css_select("div.project-panels > div.panel-slot > section.panel").size
      assert_operator slots.size, :>, 0, "and the count is not vacuously zero"
    end

    test "new blocks render first, in row order, when the layout does not name them" do
      a = block!(kind: "text", body: "a")
      b = block!(kind: "text", body: "b")
      get project_path(@project)
      ids = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["id"] }
      assert_equal [ bkey(a), bkey(b), "attachments" ], ids.first(3)
    end

    # --- the edit page -------------------------------------------------------------------------------

    test "the edit page carries the Add block menu, one template per kind, the page intro and each block's editor" do
      text = block!(kind: "text", heading: "Why", body: "Because.")
      link = block!(kind: "link", heading: "P", url: "https://p.example/x", line: "l")
      image = block!(kind: "image", node_id: @side.node_id, caption: "c")

      get edit_layout_project_path(@project)

      assert_select "details.layout-add[data-layout-editor-target=addMenu]" do
        %w[text link image].each { |k| assert_select "button[data-action='layout-editor#addBlock'][data-kind=?]", k, 1 }
      end
      %w[text link image].each do |k|
        assert_select "template[data-layout-editor-target=blockTemplate][data-kind=?]", k, 1
      end
      assert_select "div.page-intro[data-layout-editor-target=page][data-description=?]", "A lamp." do
        assert_select "textarea[data-action='input->layout-editor#description']", text: "A lamp."
        assert_select "button.cover-pick[data-action='layout-editor#pickCover'][data-node-id=?]", @side.node_id, 1
        assert_select "button.cover-pick[data-node-id=?]", @front.node_id, 1
        assert_select "button[data-action='layout-editor#removeCover']", 1
      end
      assert_select "div.panel-slot[data-key=?][data-kind=text][data-heading=Why]", bkey(text) do
        assert_select ".panel-strip button[data-action='layout-editor#deleteBlock']", 1
        assert_select ".panel-strip details.panel-strip-edit", count: 0
        assert_select ".panel-strip button[data-action='layout-editor#view']", count: 0
        assert_select "form.block-editor input[data-field=heading][value=Why]", 1
        assert_select "form.block-editor textarea[data-field=body]", text: "Because."
        assert_select "form.block-editor button[data-action='layout-editor#previewMarkdown']", 1
        assert_select "div.block-preview[data-layout-editor-target=preview]", 1
      end
      # THE BODY RIDES THE SLOT TOO, AND IT IS ASSERTED SEPARATELY: `[data-body=Because.]` is not a
      # CSS identifier (the full stop), so it belongs in a value comparison rather than a selector.
      assert_equal "Because.", css_select("div.panel-slot[data-key='#{bkey(text)}']").first["data-body"]
      assert_select "div.panel-slot[data-key=?][data-kind=link][data-url=?][data-link-title=P][data-line=l]",
                    bkey(link), "https://p.example/x" do
        assert_select "form.block-editor input[data-field=url][value=?]", "https://p.example/x"
        assert_select "form.block-editor input[data-field=linkTitle][value=P]", 1
        assert_select "a.block-link-card .block-link-host", text: "p.example"
      end
      assert_select "div.panel-slot[data-key=?][data-kind=image][data-file=?][data-caption=c]", bkey(image), @side.node_id do
        assert_select "button.image-pick[data-action='layout-editor#pickImage'][data-node-id=?].active", @side.node_id, 1
        assert_select "button.image-pick[data-node-id=?]", @front.node_id, 1
        assert_select "form.block-editor input[data-field=caption][value=c]", 1
      end
    end

    test "Add block is disabled at the cap" do
      Maker::ProjectBlock::CAP.times { |i| block!(kind: "text", body: "b#{i}") }
      get edit_layout_project_path(@project)
      assert_select "details.layout-add button[data-action='layout-editor#addBlock'][disabled]", 3
      assert_select "details.layout-add .layout-add-cap", text: /#{Maker::ProjectBlock::CAP} blocks/
    end

    # --- the preview helper -----------------------------------------------------------------------------

    test "preview renders sanitised Markdown for the owner and nobody else" do
      # THE RAW HTML IS QUOTED ON PURPOSE. kramdown leaves an UNQUOTED `<img src=x onerror=…>` as
      # escaped TEXT, so the literal word "onerror" survives into the document and the refutation
      # below could never pass over markup that was in fact neutralised — measured, not assumed
      # (`Maker::Markdown.render` on the unquoted form answers `&lt;img src=x onerror=alert(1)&gt;`).
      post preview_project_layout_path(@project),
           params: { markdown: %(**b** <img src="x" onerror="alert(1)"> [a](javascript:x)) }, as: :json
      assert_response :success
      assert_includes response.body, "<strong>b</strong>"
      refute_includes response.body, "onerror"
      refute_includes response.body, "javascript:"

      post preview_project_layout_path(@project), params: { markdown: "x" * (Maker::ProjectBlock::BODY_MAX + 1) }, as: :json
      assert_response :unprocessable_entity

      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")
      post preview_project_layout_path(theirs), params: { markdown: "x" }, as: :json
      assert_response :not_found
    end

    # --- Save --------------------------------------------------------------------------------------------

    def draft_with(*entries, page: nil)
      base = { layout: 1, panels: entries + [ { key: "attachments", hidden: false, width: "full", view: "tiles" } ] }
      base[:page] = page if page
      base
    end

    test "Save creates, updates and deletes block rows, rewrites new keys into the order, and sets the page" do
      keep = block!(kind: "text", heading: "Keep", body: "old body")
      gone = block!(kind: "link", heading: "Gone", url: "https://g.example")
      draft = draft_with(
        { key: "block:new-1", kind: "link", hidden: false, width: "half", url: "https://p.example/x", title: "P", line: "l" },
        { key: keep.layout_key, kind: "text", hidden: true, width: "half", heading: "Kept", body: "new body" },
        { key: "block:new-2", kind: "image", hidden: true, width: "full", file: @side.node_id, caption: "c" },
        page: { description: "Rewritten.", cover: @front.node_id }
      )

      assert_difference -> { @project.blocks.count }, +1 do
        patch project_panels_path(@project), params: { layout: draft.to_json }
      end
      assert_redirected_to project_path(@project)
      @project.reload
      assert_nil Maker::ProjectBlock.find_by(id: gone.id), "a block absent from the draft is destroyed"
      keep.reload
      assert_equal [ "Kept", "new body" ], [ keep.heading, keep.body ]
      new_link = @project.blocks.find_by(kind: "link")
      assert_equal [ "P", "https://p.example/x", "l" ], [ new_link.heading, new_link.url, new_link.line ]
      new_image = @project.blocks.find_by(kind: "image")
      assert_equal [ @side.node_id, "c" ], [ new_image.node_id, new_image.caption ]
      order = @project.panels["order"]
      assert_equal [ new_link.layout_key, keep.layout_key, new_image.layout_key, "attachments" ], order.first(4)
      refute order.any? { |k| k.include?("new-") }, "no placeholder key survives Save"
      refute_includes order, gone.layout_key, "and the destroyed block leaves the order with it"
      assert_equal [ keep.layout_key, new_image.layout_key ].sort, @project.panels["hidden"].sort, "a hidden NEW block's key is rewritten in hidden too"
      assert_equal "half", @project.panels["widths"][new_link.layout_key]
      assert_equal "Rewritten.", @project.description
      assert_equal @front.node_id, @project.cover_node_id
    end

    test "a bad block in the draft writes nothing at all" do
      keep = block!(kind: "text", body: "old")
      draft = draft_with(
        { key: keep.layout_key, kind: "text", hidden: false, width: "full", body: "changed" },
        { key: "block:new-1", kind: "link", hidden: false, width: "half", url: "javascript:x", title: "bad" },
        page: { description: "Changed.", cover: nil }
      )
      assert_no_difference -> { @project.blocks.count } do
        patch project_panels_path(@project), params: { layout: draft.to_json }
      end
      assert_redirected_to edit_layout_project_path(@project)
      assert_match(/not saved/, flash[:alert])
      assert_equal "old", keep.reload.body
      assert_equal "A lamp.", @project.reload.description
    end

    # THE MODEL IS THE SECOND LOCK AND THE TRANSACTION IS WHAT MAKES IT SAFE (spec §5). `https://[`
    # passes Maker::LayoutDocument's URL_FORMAT — that pattern asks about the SHAPE of the string
    # and never parses it — and fails Maker::ProjectBlock, whose `valid_link_url?` does. So the
    # draft is accepted, the earlier block is UPDATED, and only then does a row refuse to save:
    # without one transaction around the lot, this Save would leave half a document written.
    test "a block the document accepts and the model refuses rolls the whole Save back" do
      keep = block!(kind: "text", body: "old")
      draft = draft_with(
        { key: keep.layout_key, kind: "text", hidden: false, width: "full", body: "changed" },
        { key: "block:new-1", kind: "link", hidden: false, width: "half", url: "https://[", title: "bad" },
        page: { description: "Changed.", cover: nil }
      )
      assert_no_difference -> { @project.blocks.count } do
        patch project_panels_path(@project), params: { layout: draft.to_json }
      end
      assert_redirected_to edit_layout_project_path(@project)
      assert_match(/not saved/, flash[:alert])
      assert_equal "old", keep.reload.body, "the block written before the refusal was rolled back"
      assert_equal "A lamp.", @project.reload.description
    end

    # THE DRAFT STILL LISTS ITS BLOCK, and that is not incidental: the browser posts every slot it
    # holds, so a block absent from a draft means "deleted" (the Save test above pins it) — a draft
    # written here without one would be testing that deletion, not the page section.
    test "a draft without a page section leaves the description and cover alone, and Reset leaves blocks alone" do
      block = block!(kind: "text", body: "x")
      @project.update!(cover_node_id: @front.node_id)
      patch project_panels_path(@project),
            params: { layout: draft_with({ key: block.layout_key, kind: "text", hidden: false, width: "full", body: "x" }).to_json }
      assert_equal [ "A lamp.", @front.node_id ], [ @project.reload.description, @project.cover_node_id ]

      delete project_panels_path(@project)
      assert_equal 1, @project.blocks.count
      assert_equal "A lamp.", @project.reload.description
    end

    # THE COVER FREEZE (found in review): `Maker::Project#cover_node_id` derives a cover from the
    # attachments when none is chosen. Drafting THAT and writing it back would turn the guess into a
    # choice on every Save, and the hero would stop following the attachments.
    test "a Save that says nothing new about the cover leaves a derived cover derived" do
      @project.file_attachments.create!(user: @user, node_id: @front.node_id, role: "image", position: 0)
      assert_nil @project.reload[:cover_node_id]
      assert_equal @front.node_id, @project.cover_node_id, "derived from the attachment"

      get edit_layout_project_path(@project)
      assert_select "div.page-intro[data-cover='']", 1, "the draft carries the stored column, not the derived pick"
      assert_select "div.page-intro .cover-current", text: "front.png"
      assert_select "div.page-intro button.cover-pick.active[data-node-id=?]", @front.node_id, 1

      patch project_panels_path(@project), params: { layout: draft_with(page: { description: "A lamp.", cover: nil }).to_json }
      assert_redirected_to project_path(@project)
      assert_nil @project.reload[:cover_node_id], "the column stays unset"
      assert_equal @front.node_id, @project.cover_node_id, "and the cover keeps following"
    end

    test "a text block's relative link resolves against the project folder, and an unresolvable one is plain text" do
      block!(kind: "text", body: "See [side](photos/side.jpg) and [gone](photos/nope.jpg).")
      get project_path(@project)
      assert_select "section.block--text .markdown a[href=?]", file_path(@side.node_id), text: "side"
      assert_select "section.block--text .markdown a", count: 1
      assert_select "section.block--text .markdown", text: /gone/
    end

    test "the drawer's YAML says when the page holds an entry it cannot save, and the editor renders the cap" do
      draft = { layout: 1, panels: [ { key: "block:new-1", kind: "text", hidden: false, width: "full" } ] }
      post yaml_project_layout_path(@project), params: { draft: draft.to_json }
      assert_response :success
      assert_match(/\A# The page holds an entry that cannot be saved yet \(Entry 1: a text block needs a heading or a body\.\); this is the last saved layout\.\n/, response.body)

      get edit_layout_project_path(@project)
      assert_select "div.layout-editor[data-layout-editor-block-cap-value=?]", Maker::ProjectBlock::CAP.to_s, 1
    end

    test "Save refuses a draft over the cap" do
      Maker::ProjectBlock::CAP.times { |i| block!(kind: "text", body: "b#{i}") }
      entries = @project.blocks.map { |b| { key: b.layout_key, kind: "text", hidden: false, width: "full", body: b.body } }
      entries << { key: "block:new-1", kind: "text", hidden: false, width: "full", body: "one more" }
      patch project_panels_path(@project), params: { layout: draft_with(*entries).to_json }
      assert_redirected_to edit_layout_project_path(@project)
      assert_equal Maker::ProjectBlock::CAP, @project.blocks.count
    end
  end
end
