require "test_helper"

module Web
  # The sitewide search results page (stage 2, S2-5): one page grouped by kind -- files, projects,
  # models, inventory, tags -- five rows per kind with a "See all" into that kind's own index,
  # bounded and escaped exactly like the Files page's own ?q= (files_search_test.rb). Renders
  # `shared/_result_group.html.erb` (Task A's contract). Nodes are created directly, as
  # files_search_test.rb does -- a listing test is about the query, not the bytes.
  #
  # EACH TEST BUILDS ITS OWN FIXTURES rather than sharing a common setup beyond signing in: five
  # different kinds each need EXACT counts for the "five per group, See all N" assertions to mean
  # anything, and a shared pool of "lamp"-matching records across tests would silently inflate
  # those counts.
  class SearchTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "search-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "one query, five kinds: each group renders its matches with a working link" do
      file = @user.nodes.create!(node_id: "n-lamp-base", name: "lamp-base.stl", kind: "file")
      by_name = @user.maker_projects.create!(name: "Desk Lamp")
      by_description = @user.maker_projects.create!(name: "Workshop Overhaul",
                                                     description: "New lamp mounts for the bench.")
      model = @user.maker_models.create!(title: "lamp-shade")
      by_item_name = @user.maker_inventory_items.create!(name: "12 V lamp brick")
      by_part_number = @user.maker_inventory_items.create!(name: "Bracket", part_number: "LAMP-42")
      tag = @user.maker_tags.create!(name: "lamp")

      get search_path(q: "lamp")
      assert_response :success
      assert_select "h1", text: "Search"
      assert_select ".search-toolbar input[name='q'][value='lamp']"

      assert_select ".result-group--file", count: 1
      assert_select ".result-group--file a[href=?]", file_path(file.node_id), text: "lamp-base.stl"

      assert_select ".result-group--project", count: 1
      assert_select ".result-group--project a[href=?]", project_path(by_name), text: "Desk Lamp"
      assert_select ".result-group--project a[href=?]", project_path(by_description), text: "Workshop Overhaul"

      assert_select ".result-group--model", count: 1
      assert_select ".result-group--model a[href=?]", model_path(model), text: "lamp-shade"

      assert_select ".result-group--inventory_item", count: 1
      assert_select ".result-group--inventory_item a[href=?]", inventory_item_path(by_item_name), text: "12 V lamp brick"
      assert_select ".result-group--inventory_item a[href=?]", inventory_item_path(by_part_number), text: "Bracket"

      assert_select ".result-group--tag", count: 1
      assert_select ".result-group--tag a.tag-chip[href=?]", tag_path(tag.name), text: "lamp"
    end

    test "a group renders only when it has matches" do
      @user.nodes.create!(node_id: "n-widget-only", name: "widget-only.stl", kind: "file")

      get search_path(q: "widget-only")
      assert_select ".result-group--file", count: 1
      assert_select ".result-group--project", count: 0
      assert_select ".result-group--model", count: 0
      assert_select ".result-group--inventory_item", count: 0
      assert_select ".result-group--tag", count: 0
    end

    test "five results per group, with a See all link to the rest" do
      7.times { |i| @user.nodes.create!(node_id: "many-file-#{i}", name: "widget-#{i}.stl", kind: "file") }
      7.times { |i| @user.maker_models.create!(title: "widget-model-#{i}") }
      7.times { |i| @user.maker_inventory_items.create!(name: "widget-item-#{i}") }
      7.times { |i| @user.maker_projects.create!(name: "Widget Project #{i}") }

      get search_path(q: "widget")
      assert_response :success

      assert_select ".result-group--file .result-row", count: 5
      assert_select ".result-group--file .result-more a[href=?]", files_path(q: "widget"), text: /See all 7/

      assert_select ".result-group--model .result-row", count: 5
      assert_select ".result-group--model .result-more a[href=?]", files_models_path(q: "widget"), text: /See all 7/

      assert_select ".result-group--inventory_item .result-row", count: 5
      assert_select ".result-group--inventory_item .result-more a[href=?]", inventory_items_path(q: "widget"), text: /See all 7/

      assert_select ".result-group--project .result-row", count: 5
      assert_select ".result-group--project .result-more a[href=?]", projects_path(q: "widget"), text: /See all 7/
    end

    # Task A adds `?q=` to ProjectsController#index (ground rules: the two of us would otherwise
    # both edit the same two files); this is the narrowing test the plan puts here rather than in
    # project_page_test.rb, so it can only run once that commit lands.
    test "projects_path(q:) narrows the projects index" do
      @user.maker_projects.create!(name: "Desk Lamp")
      @user.maker_projects.create!(name: "Unrelated Bracket")

      get projects_path(q: "lamp")
      assert_response :success
      assert_select ".project-name", text: "Desk Lamp"
      assert_select ".project-name", text: "Unrelated Bracket", count: 0
    end

    test "the query is escaped: % and _ are literal, not wildcards" do
      @user.nodes.create!(node_id: "pct-file", name: "100%.stl", kind: "file")
      @user.nodes.create!(node_id: "decoy-file", name: "100-decoy.stl", kind: "file")
      get search_path(q: "100%")
      assert_select ".result-group--file a", text: "100%.stl"
      assert_select ".result-group--file a", text: "100-decoy.stl", count: 0

      @user.nodes.create!(node_id: "underscore-file", name: "under_score.stl", kind: "file")
      @user.nodes.create!(node_id: "plain-file", name: "regular.stl", kind: "file")
      get search_path(q: "_")
      assert_select ".result-group--file a", text: "under_score.stl"
      assert_select ".result-group--file a", text: "regular.stl", count: 0
    end

    test "a long query is truncated and does not error" do
      get search_path(q: "a" * 200)
      assert_response :success
      assert_select ".search-toolbar input[name='q'][value=?]", "a" * SearchController::QUERY_MAX
    end

    test "hidden and deleted files do not surface" do
      @user.nodes.create!(node_id: "visible-lamp", name: "lamp-visible.stl", kind: "file")
      @user.nodes.create!(node_id: "deleted-lamp", name: "lamp-deleted.stl", kind: "file", deleted: true)
      @user.nodes.create!(node_id: "dotfile-lamp", name: ".lamp-hidden.stl", kind: "file")

      get search_path(q: "lamp")
      assert_select ".result-group--file a", text: "lamp-visible.stl"
      assert_select ".result-group--file a", text: "lamp-deleted.stl", count: 0
      assert_select ".result-group--file a", text: ".lamp-hidden.stl", count: 0
    end

    # STAGE 4, S4-2, STORY 4.8. Search reads the SAME `visible_entries(false)` scope a folder view
    # does, so build output follows for free — driven, not reasoned: a future search that stopped
    # calling the scope would go red here rather than quietly listing 440 object files.
    #
    # THE ASSERTION THAT CARRIES THE WEIGHT IS THE FILE ONE, and that is worth saying plainly.
    # A BUILD DIRECTORY IS EXCLUDED FROM THE FOLDERS GROUP BY `visible_entries(false)` — the same
    # display filter the Files page applies (Library::BuildOutput) — and since stage 4, S4-8 that is a
    # live assertion rather than a vacuous one: this suite used to say the directory "can never fail"
    # because the controller filtered `kind: "file"` first, which stopped being true the day search
    # gained a Folders group (found in review: dropping the scope left this test green).
    test "build output does not surface, and a file of the same name still does" do
      @user.nodes.create!(node_id: "s-nm-dir", name: "node_modules", kind: "dir")
      @user.nodes.create!(node_id: "s-nm-file", name: "node_modules", kind: "file")
      @user.nodes.create!(node_id: "s-nm-js", name: "node_modules.js", kind: "file")

      get search_path(q: "node_modules")
      assert_response :success
      assert_select ".result-group--file a[href=?]", file_path("s-nm-file"), text: "node_modules"
      assert_select ".result-group--file a[href=?]", file_path("s-nm-js"), text: "node_modules.js"
      assert_select ".result-group--file a[href=?]", file_path("s-nm-dir"), count: 0
      assert_select ".result-group--folder a[href=?]", files_path(folder: "s-nm-dir"), { count: 0 },
                    "a build directory must not surface as a folder either"
    end

    test "a blank query renders the prompt, never the empty-results message" do
      get search_path
      assert_response :success
      assert_select "p.search-prompt"
      assert_select ".result-group", count: 0
      assert_select ".empty", count: 0

      get search_path(q: "   ")
      assert_select "p.search-prompt"
      assert_select ".result-group", count: 0
    end

    test "a query with no matches says so, and drops the prompt" do
      get search_path(q: "nothing-here-at-all")
      assert_select ".empty", text: /Nothing matches “nothing-here-at-all”/
      assert_select "p.search-prompt", count: 0
    end

    test "tenancy: another user's project, item and tag never appear" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Lamp From Someone Else")
      other.maker_inventory_items.create!(name: "Other lamp item")
      other.maker_tags.create!(name: "lamp")
      @user.maker_projects.create!(name: "My Own Lamp Project")

      get search_path(q: "lamp")
      assert_select ".result-group--project a", text: "My Own Lamp Project"
      assert_select ".result-group--project a", text: "Lamp From Someone Else", count: 0
      assert_select ".result-group--inventory_item a", text: "Other lamp item", count: 0
      # @user owns no "lamp" tag here, so the group must be wholly ABSENT even though `other`
      # does -- proof the tags query is user-scoped, not merely silent by coincidence.
      assert_select ".result-group--tag", count: 0
    end

    # A NOTE IS THE ONE THING A MAKER WRITES THAT THE APP KEEPS AND COULD NOT FIND (story 3.5).
    # The body is Action Text, so the match is over `action_text_rich_texts.body` reached through
    # the `rich_text_body` association `has_rich_text :body` declares — the association carries
    # `record_type` and `name = 'body'` itself, so there is no hand-written ON clause to drift.
    test "a note body is searchable and its row links to the file the note is on" do
      node = @user.nodes.create!(node_id: "n-noted", name: "shade.stl", kind: "file")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>Cut this one on the LAMP jig.</div>")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>Nothing to do with it.</div>")

      get search_path(q: "lamp")
      assert_response :success
      assert_select ".result-group--note", count: 1
      assert_select ".result-group--note a[href=?]", file_path(node.node_id), text: "shade.stl"
      # THE SNIPPET IS PLAIN TEXT, NOT THE STORED HTML. `to_plain_text` is what keeps the markup
      # out of a results row — a raw body would render the tags as escaped noise on every hit.
      #
      assert_select ".result-group--note .result-sub", text: "Cut this one on the LAMP jig."
      # AND NO ELEMENT INSIDE THE SPAN — THIS IS THE ASSERTION THAT CATCHES A RAW BODY, and which
      # one it is cost a mutation check to learn. `truncate` on an Action Text body neither
      # escapes NOR truncates it: the value arrives html_safe, so the note's own tags and Action
      # Text's `<div class="lexxy-content">` wrapper are injected into the row as REAL DOM. The
      # rendered TEXT is then identical either way, so every `text:` assertion above — exact or
      # regex — stays green over a row carrying an un-truncated block element. The structure is
      # what differs, so the structure is what is asserted. Mutation-checked with
      # `record.body.to_s` in the partial: the two lines above stay GREEN, this one goes red.
      assert_select ".result-group--note .result-sub *", count: 0
      assert_select ".result-group--note .result-sub", text: /Nothing to do with it/, count: 0
    end

    # A NOTE WHOSE FILE IS GONE HAS NOWHERE TO LINK. `.present` is the same filter every other
    # file-facing surface applies; without it the row renders a link to a dead /files/:id.
    test "a note on a tombstoned or absent file does not surface" do
      dead = @user.nodes.create!(node_id: "n-dead", name: "lamp-old.stl", kind: "file", deleted: true)
      @user.maker_notes.create!(node_id: dead.node_id, body: "<div>lamp notes</div>")
      @user.maker_notes.create!(node_id: "never-existed", body: "<div>lamp notes</div>")

      get search_path(q: "lamp")
      assert_select ".result-group--note", count: 0
    end

    # FOLDERS, BY NAME — the only spelling of "find my folder path" all three backends can answer.
    # `nodes.storage_path` is written by the Share and S3 adapters ONLY, so a LIKE over it is
    # structurally empty on chunk_remote (the plan's Amendment 5).
    test "a folder is a result of its own, linking into the Files page's folder view" do
      dir = @user.nodes.create!(node_id: "d-lamps", name: "lamps", kind: "dir")
      @user.nodes.create!(node_id: "d-hidden", name: ".lamps", kind: "dir")
      @user.nodes.create!(node_id: "d-gone", name: "lamps-old", kind: "dir", deleted: true)

      get search_path(q: "lamp")
      assert_select ".result-group--folder", count: 1
      assert_select ".result-group--folder a[href=?]", files_path(folder: dir.node_id), text: "lamps"
      assert_select ".result-group--folder a", text: ".lamps", count: 0
      assert_select ".result-group--folder a", text: "lamps-old", count: 0
    end

    # THE SAME ESCAPE RULE AS EVERY OTHER GROUP, AND BOTH HALVES CARRY WEIGHT (measured in review):
    # without `ESCAPE` SQLite reads the sanitizer's backslash literally and the pattern matches
    # NOTHING; without the sanitizer `%` is a wildcard and the decoy matches. Two mutations, two reds.
    test "the two new groups escape LIKE metacharacters too" do
      node = @user.nodes.create!(node_id: "n-pct", name: "pct.stl", kind: "file")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>done at 100% power</div>")
      @user.maker_notes.create!(node_id: node.node_id, body: "<div>100-decoy</div>")
      @user.nodes.create!(node_id: "d-pct", name: "100% jobs", kind: "dir")
      @user.nodes.create!(node_id: "d-decoy", name: "100-decoy", kind: "dir")

      get search_path(q: "100%")
      assert_select ".result-group--note .result-sub", text: /100% power/
      assert_select ".result-group--note .result-sub", text: /100-decoy/, count: 0
      assert_select ".result-group--folder a", text: "100% jobs"
      assert_select ".result-group--folder a", text: "100-decoy", count: 0
    end

    test "tenancy: another user's note and folder never appear" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      node = other.nodes.create!(node_id: "n-theirs", name: "lamp.stl", kind: "file")
      other.maker_notes.create!(node_id: node.node_id, body: "<div>their lamp note</div>")
      other.nodes.create!(node_id: "d-theirs", name: "lamps", kind: "dir")

      get search_path(q: "lamp")
      assert_select ".result-group--note", count: 0
      assert_select ".result-group--folder", count: 0
    end
  end
end
