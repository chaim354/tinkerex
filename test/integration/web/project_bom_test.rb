require "test_helper"

module Web
  # The bill of materials (stage 2, S2-4): the project page's capped panel and the full page at
  # /projects/:id/bom, the three write doors (Projects::BomLinesController — create / destroy /
  # consume) and Projects::BomsController#show, and the rollup line both surfaces share
  # (Maker::BomRollup, rendered once by projects/_bom_lines.html.erb).
  #
  # DEVIATION FROM THE PLAN'S PROSE, KEPT DELIBERATE: the plan's test-bullet list glosses a text/
  # file line's Consume refusal as "422/alert", but the plan's OWN controller sketch (Step 2)
  # answers it with `back_to(project, alert: …)` — the identical redirect-with-flash shape every
  # other refusal in this controller uses (a blank stock item, an unowned file). There is no
  # special-cased 422 anywhere in that sketch, and a session-authed HTML controller redirecting
  # with an alert is this app's house shape for a rejected mutation (CLAUDE.md §14d). Implemented
  # and tested as a redirect + alert, matching the concrete code over the terse gloss.
  class ProjectBomTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "bom-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    def other_user!
      User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                   confirmed_at: Time.current)
    end

    def item!(name: "NEMA17", unit: "each", unit_cost: nil, balance: 0)
      item = @user.maker_inventory_items.create!(name:, unit:, unit_cost:)
      Maker::InventoryTransaction.apply!(item:, user: @user, delta: balance, reason: "initial") if balance != 0
      item.reload
    end

    def node!(name: "lamp-base.stl", node_id: SecureRandom.uuid)
      @user.nodes.create!(node_id:, name:, kind: "file")
    end

    def bom!
      @project.boms.create!(user: @user)
    end

    def line!(bom, **attrs)
      bom.lines.create!(user: @user, quantity: 1, unit: "each",
                        position: (bom.lines.maximum(:position) || -1) + 1, **attrs)
    end

    # --- the panel ---------------------------------------------------------------------------

    test "the panel lists lines of all three kinds" do
      item = item!(name: "NEMA17", balance: 4)
      node = node!(name: "lamp-base.stl")
      supplier = @user.maker_suppliers.create!(name: "McMaster")
      bom = bom!
      line!(bom, inventory_item: item, quantity: 2, unit: "each")
      line!(bom, node_id: node.node_id, quantity: 1, unit: "each")
      line!(bom, part_name: "22 AWG wire", quantity: 3, unit: "m", supplier:)

      get project_path(@project)
      assert_response :success
      assert_select "section.panel.bom-panel h2", text: "Bill of materials"
      assert_select ".bom-rev", text: "rev 1"
      assert_select "table.table.bom-lines tbody tr", count: 3
      assert_select ".badge.bom-stock", text: "stock"
      assert_select ".badge.bom-file", text: "file"
      assert_select ".badge.bom-text", text: "text"
      assert_select ".col-target a[href=?]", inventory_item_path(item)
      assert_select ".col-target a[href=?]", file_path(node.node_id), text: node.name
      assert_select ".col-target", text: /22 AWG wire/
      assert_select ".col-supplier", text: /McMaster/
      assert_select ".col-stock", text: /4 on hand/
    end

    test "a file line whose node is gone says so" do
      bom = bom!
      line!(bom, node_id: "missing-node", quantity: 1, unit: "each")

      get project_path(@project)
      assert_select ".col-target", text: /no longer in your library/
      assert_select ".col-target a", count: 0
    end

    test "the rollup line" do
      item = item!(name: "NEMA17", balance: 4)
      bom = bom!
      line!(bom, inventory_item: item, quantity: 2, unit: "each")
      line!(bom, node_id: node!.node_id, quantity: 1, unit: "each")
      line!(bom, part_name: "Wire", quantity: 3, unit: "m")

      get project_path(@project)
      rollup_text = css_select(".bom-rollup").text
      assert_match(/3 lines/, rollup_text)
      assert_match(/1 from stock/, rollup_text)
      assert_match(/1 file/, rollup_text)
      assert_match(/1 free text/, rollup_text)
      assert_no_match(/est\./, rollup_text)

      item.update!(unit_cost: 11.50)
      get project_path(@project)
      assert_match(/est\. \$23\.00/, css_select(".bom-rollup").text)
    end

    test "a short stock line is marked" do
      item = item!(name: "NEMA17", balance: 1)
      bom = bom!
      line!(bom, inventory_item: item, quantity: 2, unit: "each")

      get project_path(@project)
      assert_select "tr.short .col-stock", text: /1 on hand/
      assert_match(/1 short/, css_select(".bom-rollup").text)
    end

    # ONE LINE, SO THE PANEL IS NOT QUIET. Since stage 4, S4-1 the project page's BOM panel renders
    # projects/_bom_lines — the table, the rollup AND this composer — only when it has lines; an
    # empty panel is its heading and Open, and adding the first line happens on the BOM page. That
    # surface's own composer is asserted by "the page with no BOM renders the empty state and the
    # composer" below, so the no-BOM-at-all case is still covered; what this test is about is the
    # rendered field names, which is a §14d rule about the form and not about which page it sits on.
    test "the composer's field names" do
      item = item!(name: "NEMA17")
      line!(bom!, inventory_item: item, quantity: 1, unit: "each")
      get project_path(@project)

      assert_select "details.composer.bom-add summary", text: "Add line"
      assert_select "form[action=?]", project_bom_lines_path(@project)
      assert_select "input[name=?]", "bom_line[reference]"
      assert_select "input[name=?]", "bom_line[quantity]"
      assert_select "select[name=?]", "bom_line[unit]" do
        Maker::BomLine::UNITS.each { |u| assert_select "option[value=?]", u }
      end
      %w[stock file text].each do |v|
        assert_select "input[type=radio][name=?][value=?]", "bom_line[target_kind]", v
      end
      assert_select "select[name=?]", "bom_line[inventory_item_id]" do
        assert_select "option", text: item.name
      end
      assert_select "input[name=?]", "bom_line[node_id]"
      assert_select "input[name=?]", "bom_line[part_name]"
      assert_select "select[name=?]", "bom_line[supplier_id]"
      assert_select "input[name=?]", "bom_line[notes]"
    end

    # --- lazy creation -------------------------------------------------------------------------

    test "the BOM is created lazily by the first line, never by a GET" do
      item = item!(name: "NEMA17")

      get project_path(@project)
      assert_equal 0, @project.boms.count

      post project_bom_lines_path(@project),
           params: { bom_line: { target_kind: "stock", inventory_item_id: item.id, quantity: "2", unit: "each" } }
      assert_equal 1, @project.boms.count
      bom = @project.boms.first
      assert_equal 1, bom.revision
      assert_equal 1, bom.lines.count
      assert_redirected_to project_path(@project)
      assert_match(/Added/, flash[:notice])

      post project_bom_lines_path(@project),
           params: { bom_line: { target_kind: "stock", inventory_item_id: item.id, quantity: "1", unit: "each" } }
      assert_equal 1, @project.boms.count, "a second line must reuse the existing bom"
      assert_equal 2, @project.boms.first.lines.count
    end

    # --- exactly one target, chosen by the radio ------------------------------------------------

    test "target_kind text keeps only the part name when an item is also filled in" do
      item = item!(name: "NEMA17")
      assert_difference "Maker::BomLine.count", 1 do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "text", part_name: "Wire", inventory_item_id: item.id,
                                   quantity: "1", unit: "each" } }
      end
      line = Maker::BomLine.last
      assert_nil line.inventory_item_id
      assert_equal "Wire", line.part_name
    end

    test "target_kind stock with a blank item is refused" do
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "stock", inventory_item_id: "", quantity: "1", unit: "each" } }
      end
      assert_redirected_to project_path(@project)
      assert_match(/pick a stock item/i, flash[:alert])
    end

    test "target_kind file with a node the user does not own is refused" do
      foreign = other_user!.nodes.create!(node_id: SecureRandom.uuid, name: "foreign.stl", kind: "file")
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "file", node_id: foreign.node_id, quantity: "1", unit: "each" } }
      end
      assert_match(/isn't in your library/, flash[:alert])

      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "file", node_id: "unknown-node", quantity: "1", unit: "each" } }
      end
      assert_match(/isn't in your library/, flash[:alert])

      # A DIRECTORY IS NOT A FILE: the lookup carries kind: "file", so a folder the user does own is
      # refused the same way — without it a line could point at a folder and link file_path to it.
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "models", kind: "dir")
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "file", node_id: folder.node_id, quantity: "1", unit: "each" } }
      end
      assert_match(/isn't in your library/, flash[:alert])
    end

    # THE RETURN PATH FOLLOWS THE REFERER: the same three doors serve the panel and the full page,
    # and redirect_back_or_to is what sends a post from /projects/:id/bom back there rather than to
    # the project page (review, 2026-09-04: nothing pinned the non-fallback arm).
    test "a line added from the full page returns to the full page" do
      item = item!(name: "NEMA17")
      post project_bom_lines_path(@project),
           params: { bom_line: { target_kind: "stock", inventory_item_id: item.id, quantity: "1", unit: "each" } },
           headers: { "HTTP_REFERER" => project_bom_path(@project) }
      assert_redirected_to project_bom_path(@project)
    end

    # A STOCK LINE IS COUNTED IN ITS ITEM'S UNIT. Consume subtracts the line's quantity from the item,
    # so the unit the row shows must be the unit the item is stocked in; the composer's unit field
    # applies to file and text lines only (review, 2026-09-04).
    test "a stock line takes its item's unit, whatever the composer sent" do
      item = item!(name: "PETG", unit: "kg")
      post project_bom_lines_path(@project),
           params: { bom_line: { target_kind: "stock", inventory_item_id: item.id, quantity: "2", unit: "each" } }
      assert_equal "kg", Maker::BomLine.last.unit
    end

    test "target_kind text with a blank part name is refused" do
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "text", part_name: "", quantity: "1", unit: "each" } }
      end
      assert_match(/enter a part name/i, flash[:alert])
    end

    test "a foreign inventory_item_id surfaces the model's error" do
      foreign_item = other_user!.maker_inventory_items.create!(name: "Not yours", unit: "each")
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "stock", inventory_item_id: foreign_item.id,
                                   quantity: "1", unit: "each" } }
      end
      assert_match(/inventory item/i, flash[:alert])
      # AND NO EMPTY BOM IS LEFT BEHIND: the bom is minted by the first line, inside the same
      # transaction, so a line the model refuses rolls the bom back with it (review, 2026-09-04).
      assert_equal 0, @project.reload.boms.count, "a rejected first line minted an empty bom"
    end

    test "a foreign supplier_id surfaces the model's error" do
      item = item!(name: "NEMA17")
      foreign_supplier = other_user!.maker_suppliers.create!(name: "Not yours")
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "stock", inventory_item_id: item.id,
                                   supplier_id: foreign_supplier.id, quantity: "1", unit: "each" } }
      end
      assert_match(/supplier/i, flash[:alert])
    end

    # --- quantity and unit validation ------------------------------------------------------------

    # THE UNIT CASE IS A TEXT LINE ON PURPOSE: a stock line takes its item's unit at the door, so a
    # bad unit on one is overridden, not refused; only file and text lines carry the composer's.
    test "quantity and unit are validated" do
      item = item!(name: "NEMA17")
      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "stock", inventory_item_id: item.id, quantity: "0", unit: "each" } }
      end
      assert flash[:alert].present?

      assert_no_difference "Maker::BomLine.count" do
        post project_bom_lines_path(@project),
             params: { bom_line: { target_kind: "text", part_name: "wire", quantity: "1", unit: "furlong" } }
      end
      assert flash[:alert].present?
    end

    # --- Consume -------------------------------------------------------------------------------

    test "Consume posts a consumed transaction against the project" do
      item = item!(name: "NEMA17", balance: 4)
      bom = bom!
      line = line!(bom, inventory_item: item, quantity: 2, unit: "each")

      assert_difference -> { item.reload.transactions.count }, 1 do
        post consume_bom_line_path(line)
      end
      assert_equal 2, item.reload.quantity_cached.to_i
      txn = item.transactions.order(:created_at, :id).last
      assert_equal "consumed", txn.reason
      assert_equal @project.id, txn.project_id
      assert_match(/BOM:/, txn.note)
      assert_match(/NEMA17/, txn.note)
      assert_redirected_to project_path(@project)
      assert_match(/Consumed 2 each of NEMA17/, flash[:notice])
    end

    test "Consume refuses a text or file line, posting no transaction" do
      bom = bom!
      text_line = line!(bom, part_name: "Wire", quantity: 1, unit: "m")
      file_line = line!(bom, node_id: node!.node_id, quantity: 1, unit: "each")

      [ text_line, file_line ].each do |line|
        assert_no_difference "Maker::InventoryTransaction.count" do
          post consume_bom_line_path(line)
        end
        assert_response :redirect
        assert_match(/only a stock line/i, flash[:alert])
      end
    end

    test "Consume on a foreign line 404s" do
      other = other_user!
      other_bom = other.maker_projects.create!(name: "Other").boms.create!(user: other)
      other_item = other.maker_inventory_items.create!(name: "Their part", unit: "each")
      other_line = other_bom.lines.create!(user: other, inventory_item: other_item, quantity: 1, unit: "each")

      post consume_bom_line_path(other_line)
      assert_response :not_found
    end

    # --- Remove ----------------------------------------------------------------------------------

    test "Remove deletes the line and redirects back" do
      bom = bom!
      line = line!(bom, part_name: "Wire", quantity: 1, unit: "m")
      assert_difference "Maker::BomLine.count", -1 do
        delete bom_line_path(line)
      end
      assert_redirected_to project_path(@project)
      assert_match(/Removed/, flash[:notice])
    end

    test "Remove on a foreign line 404s" do
      other = other_user!
      other_bom = other.maker_projects.create!(name: "Other").boms.create!(user: other)
      other_line = other_bom.lines.create!(user: other, part_name: "Theirs", quantity: 1, unit: "each")

      delete bom_line_path(other_line)
      assert_response :not_found
    end

    # --- panel cap vs. the full page --------------------------------------------------------------

    test "the panel is capped; the page is not" do
      bom = bom!
      cap = Projects::BomLinesController::PANEL_CAP
      now = Time.current
      rows = (cap + 1).times.map do |i|
        { user_id: @user.id, bom_id: bom.id, part_name: "Part #{i}", quantity: 1, unit: "each",
          position: i, created_at: now, updated_at: now }
      end
      Maker::BomLine.insert_all(rows)

      get project_path(@project)
      assert_select "table.table.bom-lines tbody tr", count: cap
      assert_select ".bom-more a[href=?]", project_bom_path(@project), text: /Showing #{cap} of #{cap + 1}/
      # THE ROLLUP COUNTS EVERY LINE, NOT THE SHOWN SLICE — a panel reading "8 lines" above
      # "Showing 8 of 9" would contradict itself (review, 2026-09-04).
      assert_select ".bom-rollup", text: /#{cap + 1} lines/

      get project_bom_path(@project)
      assert_response :success
      assert_select "h1", text: "Bill of materials"
      assert_select ".breadcrumb", text: /Projects/
      assert_select ".breadcrumb", text: /#{Regexp.escape(@project.name)}/
      assert_select ".breadcrumb", text: /Bill of materials/
      assert_select "table.table.bom-lines tbody tr", count: cap + 1
      assert_select "details.composer.bom-add"
      assert_select ".bom-rollup"
    end

    test "the page with no BOM renders the empty state and the composer" do
      get project_bom_path(@project)
      assert_response :success
      assert_select "p.muted", text: "No lines yet."
      assert_select "details.composer.bom-add"
      assert_equal 0, @project.boms.count
    end

    # --- a deleted inventory item ------------------------------------------------------------------

    test "a line whose item was deleted renders as text" do
      item = item!(name: "NEMA17", balance: 4)
      bom = bom!
      line!(bom, inventory_item: item, quantity: 2, unit: "each")

      item.destroy!

      get project_path(@project)
      assert_select ".badge.bom-text", text: "text"
      assert_select ".col-target", text: /NEMA17/
    end
  end
end
