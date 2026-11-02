require "test_helper"

module Web
  # RECENT'S NEEDS ATTENTION, AFTER THE UX AUDIT (2026-11-01, E6). A failed print sat there for 30
  # days with no way to dismiss it; its "Log a print" opened the model page on its instructions PDF;
  # and a low-stock item's name was plain text beside a model name that linked.
  #
  # THE DISMISSAL IS THE WORK ITSELF, NOT A STORED FLAG (HomeController::ATTENTION_WINDOW): a failed
  # print shows for 7 days, and only while it is still the model's answer — a later print of that
  # model, or the model's status set to anything but Failed, takes it off.
  #
  # MUTATION-CHECKED (§15): dropping `.where(LATEST_RUN)` reddens "only a model's latest failure
  # shows"; dropping the print_status clause reddens "setting the status takes it off"; ATTENTION_WINDOW
  # back to 30.days reddens "a week-old failure has left". ("A later print takes a failure off" is
  # held by both clauses at once, so neither alone turns it red.) Outputs in this task's report.
  class HomeAttentionTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "attn-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
      @model = @user.maker_models.create!(title: "Tetra")
    end

    def failed!(on, model: @model, printer: nil)
      model.print_runs.create!(user: @user, printed_on: on, outcome: "failed", printer:)
    end

    def attention_rows = css_select(".home-attention .attention-row--danger").map { |r| r.text.squish }

    test "a failed print offers the print log, opened" do
      failed!(Date.current, printer: "MK4")
      get root_path
      assert_select ".home-attention .attention-row--danger", text: /Tetra failed on .* on MK4\./
      assert_select ".home-attention .attention-row--danger a.btn[href=?]",
                    model_path(@model, file: "details", log: 1, anchor: "print-log"), text: "Log a print"

      # And the link lands there: the Details pane, the composer open, the log's own anchor.
      @user.nodes.create!(node_id: "n-guide", name: "guide.pdf", kind: "file", mtime: 1, size: 1)
      @model.file_attachments.create!(user: @user, node_id: "n-guide", role: "instructions")
      get model_path(@model, file: "details", log: 1)
      assert_select "turbo-frame#model_stage .model-details section.print-log#print-log details.composer[open]"
      # Without `log=1` the composer stays closed, as it always did.
      get model_path(@model, file: "details")
      assert_select "section.print-log details.composer[open]", 0
    end

    test "a later print takes a failure off" do
      failed!(2.days.ago.to_date)
      get root_path
      assert_equal 1, attention_rows.size

      @model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success")
      get root_path
      assert_empty attention_rows
    end

    test "only a model's latest failure shows, not every one" do
      failed!(3.days.ago.to_date)
      failed!(1.day.ago.to_date, printer: "MK4")
      get root_path
      assert_equal 1, attention_rows.size
      assert_match(/on MK4/, attention_rows.first)
    end

    test "setting the model's status takes it off" do
      failed!(Date.current)
      @model.update!(print_status: "want_to_print")
      get root_path
      assert_empty attention_rows
    end

    test "a week-old failure has left" do
      failed!(8.days.ago.to_date)
      other = @user.maker_models.create!(title: "Cube")
      failed!(6.days.ago.to_date, model: other)
      get root_path
      assert_equal 1, attention_rows.size
      assert_match(/Cube/, attention_rows.first)
    end

    test "a low-stock row names its item as a link" do
      item = @user.maker_inventory_items.create!(name: "M3 bolt", unit: "each", min_quantity: 10)
      Maker::InventoryTransaction.apply!(item:, user: @user, delta: 2, reason: "initial")
      get root_path
      assert_select ".home-attention .attention-row--warn .attention-text a[href=?]", inventory_item_path(item), text: "M3 bolt"
    end

    test "Getting started links Help by its route" do
      get root_path
      assert_select ".getting-started .panel-head a[href=?]", help_path, text: "Help explains all of this"
    end
  end
end
