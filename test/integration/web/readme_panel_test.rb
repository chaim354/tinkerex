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

    test "a hidden README panel costs no port read; a shown one costs exactly one" do
      project = project!(readme: "# Lamp\n")
      reads = 0
      original = FileLayer.current.method(:read)
      counting = ->(*args, **kw) { reads += 1; original.call(*args, **kw) }

      replacing(FileLayer.current, :read, counting) { get project_path(project) }
      assert_equal 1, reads
      assert_select "#project-readme"

      project.update!(panels: { "hidden" => [ "readme" ] })
      reads = 0
      replacing(FileLayer.current, :read, counting) { get project_path(project) }
      assert_response :success
      assert_equal 0, reads
      assert_select "#project-readme", 0
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
    test "a README picture of a model whose thumbnail is ready loads from the thumbnail" do
      project = project!(readme: "![box](laser/box.lbrn2)\n")
      box = @user.nodes.present.find_by!(name: "box.lbrn2")
      token = FileLayer.current.stat(@user, node_id: box.node_id).content_token
      preview = @user.maker_previews.find_or_initialize_by(node_id: box.node_id, kind: "thumbnail")
      preview.update!(version_id: token, status: "ready",
                      renderer_revision: Maker::Previews::Enqueue.revision_for_name("box.lbrn2", "thumbnail"))
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")
      assert preview.showable?, "the fixture's preview is not showable, so the test would prove nothing"
      # What `preview_src` answers in a view: `url_for(preview.asset)`, which Active Storage resolves
      # to the redirect route (no `resolve_model_to_route` override in config/). Spelled through the
      # route helper here because the view's `url_for` needs a request to stand in.
      expected = rails_storage_redirect_path(preview.asset)

      get project_path(project)

      assert_response :success
      assert_select "#project-readme .markdown img", count: 1
      assert_select "#project-readme .markdown img[src=?]", expected
      assert_select "#project-readme .markdown img[src=?]", blob_file_path(box.node_id), 0
    end

    test "a README holding every directive costs a constant number of queries" do
      project = project!(readme: "<!-- tinkerex:files laser -->\n<!-- tinkerex:bom -->\n<!-- tinkerex:tasks -->\n<!-- tinkerex:log -->\n")
      bom = project.boms.create!(user: @user)
      seed = lambda do |n|
        n.times do |i|
          bom.lines.create!(user: @user, part_name: "part #{i}", quantity: 1, unit: "each", position: i)
          project.tasks.create!(user: @user, title: "task #{i}", status: "todo", position: i)
          project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: Time.current - i.hours, body: "<div>e#{i}</div>")
          @root.join("Projects", project.slug, "laser", "f#{i}.svg").write("<svg/>")
        end
        Library::ScanJob.new.perform(user_id: @user.id)
      end

      seed.call(2)
      get project_path(project)
      small = count_queries { get project_path(project) }
      seed.call(6)
      get project_path(project)
      large = count_queries { get project_path(project) }

      assert_equal small, large, "the README panel grows with the data: #{small} queries at the small size, #{large} at the large"
    end
  end
end
