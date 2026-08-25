require "test_helper"

module Web
  # THE FILE-CELL `data-` PAYLOAD, SWEPT ACROSS EVERY SURFACE THAT EMITS IT IN ONE TEST.
  #
  # Two JS controllers read these attributes and neither assembles anything itself:
  # `filemenu_controller.js` returns early on a missing `noteUrl` (`if (!noteUrl) return`), so a
  # cell with a download url and no note url renders NO MENU and the Download entry is unreachable;
  # `thumbs_controller.js` reads `dataset.nodeId`, so a `thumbs_target: "cell"` without one polls
  # `ids=undefined`. Both are representable, and both look perfectly fine in the rendered page.
  #
  # SIBLING OF file_menu_wiring_test.rb AND addon_origin_surfaces_test.rb, WHICH SWEEP PER SURFACE.
  # This one sweeps the PROPERTY across all of them at once, which is what catches the surface
  # nobody thought to add to a per-surface list — and the thumb-cell half was written at SEVEN sites
  # with only TWO of them guarded, four as raw HTML attributes on pages those two files never visit.
  #
  # INTEGRATION TIER, NOT CAPYBARA, deliberately: the payload is a server-rendered attribute set, so
  # an integration test runs it on all three LIBRARY_BACKEND legs where a system test runs once.
  # test/system/file_menu_test.rb covers the browser behaviour and needs no change.
  class FileCellPayloadTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
      @user = User.create!(email: "fcp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def file!(node_id, name)
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1_000_000_000, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
      node_id
    end

    # Every page in the app that renders one of these cells, and the fixtures that make each one
    # render something. Named so a failure says WHICH surface, which is the whole reason the sweep
    # is worth more than five per-page assertions.
    def surfaces
      renderable = file!("n-stl", "widget.stl")   # the .file-cell / poll-cell branch
      plain      = file!("n-txt", "readme.rtf")   # the plain-link branch, no renderer
      file!("dir-cad", "cad").then { @user.nodes.find_by!(node_id: "dir-cad").update!(kind: "dir") }

      project = @user.maker_projects.create!(name: "Lamp", cover_node_id: renderable)
      project.file_attachments.create!(user: @user, node_id: renderable, role: "model")
      project.file_attachments.create!(user: @user, node_id: plain, role: "other")
      entry = project.build_log_entries.create!(user: @user, body: "day one", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: file!("n-png", "shot.png"), role: "image")

      model = @user.maker_models.create!(title: "Case", slug: "case", cover_node_id: renderable)
      model.file_attachments.create!(user: @user, node_id: renderable, role: "model")

      { "files#index (list)" => files_path(view: "list"),
        "files#index (grid)" => files_path(view: "grid"),
        "projects#show" => project_path(project),
        "projects#index" => projects_path,
        "models#show" => model_path(model),
        "models#index" => models_path }
    end

    # THE MENU HALF. `[data-download-url]` is the presence test the existing per-surface files use;
    # this asserts the INVARIANT over every page at once and names the page that broke it.
    test "every cell offering a download carries the note url the menu is gated on" do
      counts = surfaces.to_h do |name, path|
        get path
        assert_response :success, name
        cells = css_select("[data-download-url]")
        bad = cells.reject { |el| el["data-note-url"].present? }
        assert_empty bad.map { |el| el["data-download-url"] },
                     "#{name}: a cell carries a download url and no note url, so filemenu#open " \
                     "returns early and the Download entry is unreachable"
        [ name, cells.size ]
      end

      # A SWEEP OVER NOTHING PASSES. Only three of the six pages carry a menu at all — the two card
      # indexes and models#show have no `filemenu` controller — so name the three that must, rather
      # than a bare total that a fixture change could quietly drain.
      %w[files#index\ (list) files#index\ (grid) projects#show].each do |name|
        assert_operator counts.fetch(name), :>, 0,
                        "#{name} rendered no menu cell at all — this sweep proved nothing about it"
      end
    end

    # THE THUMB-CELL HALF — the one that was written at seven sites and guarded at two. Four of the
    # seven (`projects/_log_entry`, `projects/_card`, `models/_card`, `models/_hero_poster`) emit it
    # as raw HTML attributes on pages neither file_menu_wiring_test.rb nor
    # addon_origin_surfaces_test.rb visits, so nothing anywhere asked this of them.
    test "every poll cell carries the node id the thumbs controller reads" do
      counts = surfaces.to_h do |name, path|
        get path
        assert_response :success, name
        cells = css_select("[data-thumbs-target=cell]")
        assert cells.all? { |el| el["data-node-id"].present? },
               "#{name}: a poll cell has no node id, so thumbs_controller requests ids=undefined"
        [ name, cells.size ]
      end

      # ALL SIX, because all six emit one — that is the finding. A page contributing zero would make
      # this test's `all?` pass over the very surface it was added for.
      assert_empty counts.select { |_, n| n.zero? }.keys,
                   "a surface rendered no poll cell, so the sweep says nothing about it"
    end

    # A DIRECTORY HAS NO BYTES AND NO THUMBNAIL, so the folder branches must call NEITHER builder —
    # asserted rather than assumed, because the obvious way to adopt a shared helper is to apply it
    # to every cell. file_menu_wiring_test.rb makes the same check per view; this is the half that
    # would survive someone deleting that file's folder test.
    test "folders get neither builder on either view" do
      surfaces
      %w[list grid].each do |view|
        get files_path(view:)
        assert_select "[data-download-url] .dir, a.dir[data-download-url]", count: 0
        assert_select ".grid-folder[data-thumbs-target]", count: 0
        assert_select "a.dir[data-thumbs-target]", count: 0
      end
    end
  end
end
