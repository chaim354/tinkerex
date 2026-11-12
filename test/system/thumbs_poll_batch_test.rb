require "application_system_test_case"

# THE THUMBNAIL POLL ASKS IN BATCHES (2026-11-12). thumbs_controller.js used to put every pending
# id into ONE GET, and Puma refuses a query string over 10 KB with a 400 before the app sees it: a
# node id is 39 bytes once comma-joined and encoded, so a panel of 272 pending tiles (10,609 bytes,
# measured on a dev server) failed on every poll and none of its thumbnails ever arrived. Sharing the
# project page's 300-tile budget between folders (Maker::ProjectFolderListing) is what lets one
# folder panel hold that many. Only a browser runs the poll, so only a browser can see it; the 400
# reaches the console as a failed resource load, which `assert_no_console_errors` catches.
#
# MUTATION-CHECKED: one request for every id (BATCH set past the panel's size) fails the batch-size
# assertion, which reads [8, 280] (the Recently changed row's 8, then the whole panel).
class ThumbsPollBatchTest < ApplicationSystemTestCase
  TILES = 280

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("batch@example.com")
  end

  test "a panel of 280 pending thumbnails is polled in batches the server accepts" do
    project = @user.maker_projects.create!(name: "Wall System")
    folder = project_folder_rows!(@user, project)
    @user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    plates = create_node!(@user, node_id: SecureRandom.uuid, name: "Centerpieces", kind: "dir",
                                 parent_node_id: folder.node_id, mtime: 1, size: 0)
    # NO content_hash, so no preview row is ever made and every tile stays pending: the poll keeps
    # asking for all of them, which is the request under test.
    now = Time.current
    Node.insert_all(TILES.times.map do |i|
      { node_id: SecureRandom.uuid, name: format("plate-%03d.stl", i), kind: "file", user_id: @user.id,
        parent_node_id: plates.node_id, deleted: false, mtime: 1, size: 1, created_at: now, updated_at: now }
    end)

    visit project_path(project)
    assert_selector "section.folder-panel [data-thumbs-target~='cell'] .thumb-spinner", count: TILES

    batches = lambda do
      page.evaluate_script(<<~JS)
        performance.getEntriesByType("resource").filter((e) => e.name.includes("/files/thumbnails"))
          .map((e) => decodeURIComponent(new URL(e.name).searchParams.get("ids")).split(",").length)
      JS
    end
    page.document.synchronize(10) do
      raise Capybara::ExpectationNotMet, "the first poll has not asked for every tile yet" if batches.call.sum < TILES
    end

    sizes = batches.call
    assert sizes.all? { |n| n <= 100 }, "every request stays under Puma's 10 KB query string: #{sizes.inspect}"
    assert_no_console_errors
  end
end
