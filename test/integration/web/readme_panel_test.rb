require "test_helper"

module Web
  # THE README PANEL (2026-11-05; spec 2026-11-05-readme-panel-live-regions-design.md §2, §5): the
  # project folder's README as a panel of the layout, rendered live.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS (readme_edit_test.rb's reason):
  # these pages read real bytes through the port, and the three backend legs must report identical
  # RUN counts.
  class ReadmePanelTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "panel-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # A scanned project folder holding a README and a laser/ subfolder with two files.
    def project!(readme:, files: { "laser/box.lbrn2" => "x", "laser/tokens.lbrn2" => "yy" })
      project = @user.maker_projects.create!(name: "Lamp")
      project.ensure_library_folder!(@user)
      dir = @root.join("Projects", project.slug)
      # `binwrite`: a PNG body is binary, and `write` would transcode it to UTF-8 and raise.
      files.each { |rel, body| dir.join(rel).dirname.mkpath; dir.join(rel).binwrite(body) }
      dir.join("README.md").write(readme)
      Library::ScanJob.new.perform(user_id: @user.id)
      project
    end

    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        n += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    test "the README is its own panel, first on the page, with a live files table and the editor door" do
      project = project!(readme: "# Lamp\n\n<!-- tinkerex:files laser -->\n\nstale\n\n<!-- /tinkerex -->\n")

      get project_path(project)

      assert_response :success
      assert_select ".project-panels .panel-slot:first-child #project-readme.readme-panel"
      assert_select "#project-readme .panel-head h2", text: "README"
      assert_select "#project-readme .markdown h1", text: "Lamp"
      assert_select "#project-readme .markdown table td a", text: "box.lbrn2"
      assert_select "#project-readme .markdown table td a", text: "tokens.lbrn2"
      assert_select "#project-readme .markdown", text: /stale/, count: 0
      assert_select "#project-readme .readme-editor[data-controller=readme]"
      assert_select ".attachments-panel .readme-card", 0
      assert_select ".readme-card", 0
    end

    # Every port verb a README costs this page: ONE `read` (its bytes, for the panel) and ONE `stat`
    # (its token, for the editor's `base_token`). Both counted, because a stat the controller took
    # unconditionally would stay invisible to a read-only spy (found in review).
    def counting_port_calls
      calls = Hash.new(0)
      spies = %i[read stat].to_h do |verb|
        original = FileLayer.current.method(verb)
        [ verb, ->(*args, **kw) { calls[verb] += 1; original.call(*args, **kw) } ]
      end
      replacing(FileLayer.current, :read, spies[:read]) do
        replacing(FileLayer.current, :stat, spies[:stat]) { yield }
      end
      calls
    end

    test "a hidden README panel costs no port read and no stat; a shown one costs one of each" do
      project = project!(readme: "# Lamp\n")

      shown = counting_port_calls { get project_path(project) }
      assert_equal({ read: 1, stat: 1 }, shown)
      assert_select "#project-readme"

      project.update!(panels: { "hidden" => [ "readme" ] })
      hidden = counting_port_calls { get project_path(project) }
      assert_response :success
      assert_equal({}, hidden)
      assert_select "#project-readme", 0
    end

    # A FOLDER THAT IS GONE renders no README panel at all — no heading over nothing beside the Files
    # panel's own note (found in review): there is nothing to show and no door to write one.
    test "a project whose folder is unavailable renders no README panel" do
      project = project!(readme: "# Lamp\n")
      FileLayer.current.delete(@user, node_id: project.reload.folder_node_id)

      get project_path(project)

      assert_response :success
      assert_select "#project-readme", 0
      assert_select ".readme-panel", 0
    end

    test "layout-edit mode renders the panel without the editor door" do
      project = project!(readme: "# Lamp\n")

      get edit_layout_project_path(project)

      assert_response :success
      assert_select "#project-readme .markdown h1", text: "Lamp"
      assert_select "#project-readme .readme-editor", 0
    end

    test "a non-image picture in the README is dropped until its thumbnail is ready, and an image file loads its bytes" do
      project = project!(readme: "![box](laser/box.lbrn2)\n\n![pic](photos/pic.png)\n",
                         files: { "laser/box.lbrn2" => "x", "photos/pic.png" => "\x89PNG\r\n\x1a\n".b })
      pic = @user.nodes.present.find_by!(name: "pic.png")

      get project_path(project)

      assert_select "#project-readme .markdown img[src=?]", blob_file_path(pic.node_id)
      assert_select "#project-readme .markdown img", count: 1
    end

    # THE READY ARM of ProjectsHelper#maker_image_link: a picture of a non-image file whose thumbnail
    # row is ready draws that thumbnail (`preview_src`), never the file's bytes. The row is built the
    # way maker_page_thumbnails_test.rb builds one — the content token the port reports, a ready
    # status, the current renderer revision (so the page's ThumbnailMap re-enqueues nothing) and a
    # PNG attached, which is what `showable?` asks for. `find_or_initialize_by`: the scan already
    # minted the node's PENDING row (§14b), and a Preview is one row per (user, node, kind).
    def ready_thumbnail!(node)
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
      preview = @user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
      preview.update!(version_id: token, status: "ready",
                      renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail"))
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")
      assert preview.showable?, "the fixture's preview is not showable, so the test would prove nothing"
      preview
    end

    # What `preview_src` answers in a view: `url_for(preview.asset)`, which Active Storage resolves to
    # the redirect route (no `resolve_model_to_route` override in config/). Spelled through the route
    # helper here because the view's `url_for` needs a request to stand in.
    def thumbnail_src(preview) = rails_storage_redirect_path(preview.asset)

    test "a README picture of a model whose thumbnail is ready loads from the thumbnail" do
      project = project!(readme: "![box](laser/box.lbrn2)\n")
      box = @user.nodes.present.find_by!(name: "box.lbrn2")
      preview = ready_thumbnail!(box)

      get project_path(project)

      assert_response :success
      assert_select "#project-readme .markdown img", count: 1
      assert_select "#project-readme .markdown img[src=?]", thumbnail_src(preview)
      assert_select "#project-readme .markdown img[src=?]", blob_file_path(box.node_id), 0
    end

    # THE UNION TERM (spec §5): an `image` region's node joins the page's ONE thumbnail query even when
    # no tile draws it. Here the laser folder's PANEL is hidden, so `tile_ids` leaves `box.lbrn2` out
    # and only `@readme_source.image_node_ids` can bring its ready thumbnail to the render; without
    # the term the emitter never sees a ready thumbnail and writes the link form, and this goes red.
    test "an image region's thumbnail reaches the page through the README's own union term" do
      project = project!(readme: "# Lamp\n")
      box = @user.nodes.present.find_by!(name: "box.lbrn2")
      @root.join("Projects", project.slug, "README.md").write("<!-- tinkerex:image #{box.node_id} The box -->\n")
      Library::ScanJob.new.perform(user_id: @user.id)
      laser = @user.nodes.present.find_by!(name: "laser", parent_node_id: project.reload.folder_node_id)
      project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(laser.node_id) ] })
      preview = ready_thumbnail!(box)

      get project_path(project)

      assert_response :success
      assert_select "#project-readme .markdown img[src=?]", thumbnail_src(preview)
      assert_select "#project-readme .markdown a", { text: "The box", count: 0 }, "the region is a picture, not a link"
    end

    # EVERY SOURCE A README READS GROWS WITH N, and every BOM target kind is seeded — a free-text line
    # with a supplier, an inventory item, a design file OUTSIDE the folder (the batched name lookup) —
    # because a nil foreign key costs no query at all, so a BOM of free-text lines could never show a
    # missing eager load (found in review). Measured twice: with the BOM panel shown (the controller's
    # lines reach the context) and hidden (the context loads them itself).
    test "a README holding every directive costs a constant number of queries, with the BOM panel shown or hidden" do
      project = project!(readme: "# Lamp\n")
      box = @user.nodes.present.find_by!(name: "box.lbrn2")
      @root.join("Projects", project.slug, "README.md").write(
        "<!-- tinkerex:files laser -->\n<!-- tinkerex:bom -->\n<!-- tinkerex:tasks -->\n<!-- tinkerex:log 50 -->\n" \
        "<!-- tinkerex:image #{box.node_id} -->\n"
      )
      acme = @user.maker_suppliers.create!(name: "Acme")
      bom = project.boms.create!(user: @user)
      counter = 0
      seed = lambda do |n|
        n.times do
          i = (counter += 1)
          @root.join("Projects", project.slug, "laser", "f#{i}.svg").write("<svg/>")
          @root.join("Projects", "stock-#{i}.stl").write("solid\nendsolid\n") # outside the project folder
          Library::ScanJob.new.perform(user_id: @user.id)
          outside = @user.nodes.present.find_by!(name: "stock-#{i}.stl")
          item = @user.maker_inventory_items.create!(name: "item #{i}", supplier: acme)
          bom.lines.create!(user: @user, part_name: "part #{i}", supplier: acme, quantity: 1, unit: "each", position: 3 * i)
          bom.lines.create!(user: @user, inventory_item: item, quantity: 2, unit: "each", position: 3 * i + 1)
          bom.lines.create!(user: @user, node_id: outside.node_id, quantity: 1, unit: "each", position: 3 * i + 2)
          project.tasks.create!(user: @user, title: "task #{i}", status: "todo", position: i)
          project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: Time.current - i.hours, body: "<div>e#{i}</div>")
        end
      end
      measure = lambda do |label|
        seed.call(2)
        get project_path(project)
        small = count_queries { get project_path(project) }
        seed.call(6)
        get project_path(project)
        large = count_queries { get project_path(project) }
        assert_equal small, large, "#{label}: the README panel grows with the data — #{small} queries at the small size, #{large} at the large"
      end

      measure.call("BOM panel shown")
      project.update!(panels: { "hidden" => [ "bom" ] })
      measure.call("BOM panel hidden")
    end
  end
end
