require "application_system_test_case"

# A THUMBNAIL SPINNER TURNS ONLY INSIDE A POLL CELL (F-S34-1, 2026-10-19). `files/_thumb` draws the
# same `.thumb-spinner` for every thumbnail that is not ready yet, on every surface, and only a CELL
# thumbs_controller.js reads (`data-thumbs-target="cell"`) will ever have it replaced: the poll's own
# "pending" is "a cell holding a spinner". components.css keys the animation on that cell, so a
# spinner anywhere else is a still ring rather than a promise the page cannot keep. Every PUBLIC
# surface is such a place, because /files/thumbnails is session-authed and nothing there polls.
#
# THE ANIMATION USED TO BE UNCONDITIONAL, stopped for a hand-kept list of public containers in
# pages/public.css that missed two of the six public render sites: a build-log photo and an image
# block turned forever for a visitor, and on the owner's preview of the same page. Read as the
# COMPUTED animation name, because only a browser resolves the cascade.
#
# MUTATION-CHECKED both ways: `animation` back on the bare `.thumb-spinner` reddens the public half
# (the build-log photo and the image block turn); dropping the cell-scoped rule reddens the Library
# half.
class ThumbSpinnerTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("spinner@example.com")
    @user.update!(handle: "spinner")
  end

  # Every spinner on the page as ["<container> > <box holding its thumb>", its computed animation].
  def spinners
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll(".thumb-spinner")).map((s) => {
        const box = s.closest(".thumb").parentElement;
        return [`${box.parentElement.className} > ${box.className}`, getComputedStyle(s).animationName];
      })
    JS
  end

  test "a pending thumbnail turns inside a poll cell and stands still where nothing polls" do
    # NO content_hash ON THESE ROWS, so the port reports no content token, no preview row is ever
    # backfilled, and every render below draws the spinner: on share the token IS that column.
    create_node!(@user, node_id: SecureRandom.uuid, name: "part.stl", kind: "file", mtime: 1, size: 1)
    project = @user.maker_projects.create!(name: "Desk Lamp", visibility: "public")
    folder = project_folder_rows!(@user, project)
    @user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    # THREE PUBLIC RENDER SITES: a loose file at the folder's root (`.public-files`, on the old list),
    # a build-log photo (`.entry-photos`) and an image block (`a.block-thumb`), the two it missed.
    bracket = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.stl", kind: "file",
                           parent_node_id: folder.node_id, mtime: 1, size: 1)
    shot = create_node!(@user, node_id: SecureRandom.uuid, name: "shot.png", kind: "file",
                        parent_node_id: folder.node_id, mtime: 1, size: 1)
    entry = project.build_log_entries.create!(user: @user, body: "Cut the base.", logged_at: Time.current)
    entry.file_attachments.create!(user: @user, node_id: shot.node_id, role: "image", position: 0)
    project.blocks.create!(user: @user, kind: "image", node_id: bracket.node_id)

    visit files_path(view: "grid")
    assert_selector ".files-grid [data-thumbs-target~='cell'] .thumb-spinner"
    library = spinners
    assert_equal [ "thumb-spin" ], library.map(&:last).uniq, "a Library poll cell's spinner stands still: #{library.inspect}"

    # The visitor's page, then the owner's preview, which renders the same body inside the shell.
    [ public_project_path(@user.handle, project.slug), preview_project_path(project) ].each do |path|
      visit path
      %w[.public-files .entry-photos .block-thumb].each { |site| assert_selector "#{site} .thumb-spinner" }
      seen = spinners
      turning = seen.reject { |_, name| name == "none" }
      assert_empty turning, "#{path} turns a spinner nothing on it will ever resolve: #{seen.inspect}"
    end
    assert_no_console_errors
  end
end
