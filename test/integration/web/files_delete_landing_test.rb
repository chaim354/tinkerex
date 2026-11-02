require "test_helper"

module Web
  # WHERE A DELETE LANDS, AND WHAT IT SAYS (UX audit B6, 2026-11-02). It landed on the library root
  # every time, losing the folder, the type filter and the search the maker was in; now it is the page
  # the Delete was pressed on (FilesController#delete_landing), read off the referer the way the file
  # page's Back reads it, and the notice names where the file went.
  #
  # PINNED TO A FRESH SHARE LIBRARY (create_node! writes the bytes the port moves into .trash), so the
  # delete is real and the suite runs identically on every backend leg.
  class FilesDeleteLandingTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "del-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @laser = create_node!(@user, node_id: "d-laser", name: "laser", kind: "dir")
      @file = create_node!(@user, node_id: "n-holder", name: "dice holder.lbrn2", kind: "file",
                                  parent_node_id: @laser.node_id)
    end

    def referer(path) = { "HTTP_REFERER" => "http://www.example.com#{path}" }

    # The house stub (text_file_creation_test.rb carries the same body; Minitest 6 has no
    # Object#stub): replaces a SINGLETON method for the block's duration.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    test "a delete from a filtered, searched listing lands back on that listing" do
      from = files_path(ext: "lbrn2", q: "dice")
      delete file_path(@file.node_id), headers: referer(from)

      assert_redirected_to from
      assert_equal "Deleted dice holder.lbrn2. It is in Trash.", flash[:notice]
      assert @user.nodes.find_by!(node_id: @file.node_id).deleted?, "the delete did not happen"

      # THE NOTICE CARRIES THE ONE CLICK THAT REACHES THE FILE AGAIN: Trash is where a delete is
      # undone, so the toast links it (`flash[:notice_link]`, rendered by layouts/_flash).
      follow_redirect!
      assert_select ".flash-stack .flash-notice a.flash-link[href=?]", trash_index_path, text: "Open Trash"
    end

    # THE PAGE IT WAS PRESSED ON IS GONE, so it lands where the file was. The file page's own URL is
    # the referer when its head's Delete is pressed — with a query too (a move-conflict prompt).
    test "a delete from the file's own page lands on the folder it was in" do
      delete file_path(@file.node_id), headers: referer(file_path(@file.node_id, move_conflict: "x"))
      assert_redirected_to files_path(folder: @laser.node_id)
    end

    # THE INSPECTOR'S DELETE: the listing with this file selected. The selection names a file that is
    # gone, so it alone is dropped; the folder is the maker's.
    test "a delete from the inspector drops only the selection that named the file" do
      delete file_path(@file.node_id),
             headers: referer(files_path(folder: @laser.node_id, selected: @file.node_id, scanning: 1))
      assert_redirected_to files_path(folder: @laser.node_id)
    end

    test "a folder deleted from its own listing lands on the folder it was in" do
      delete file_path(@laser.node_id), headers: referer(files_path(folder: @laser.node_id))
      assert_redirected_to files_path
      assert_equal "Deleted laser. It is in Trash.", flash[:notice]
    end

    # ANOTHER PAGE STILL THERE AFTERWARDS IS SIMPLY RETURNED TO — a project's tile, Recent.
    test "a delete from another page of the app returns to it" do
      delete file_path(@file.node_id), headers: referer(root_path)
      assert_redirected_to root_path
    end

    # NEVER AN OPEN REDIRECT: a referer on another origin is dropped, not sanitised, and with no
    # usable referer at all it is the folder the file was in.
    test "a cross-origin referer is dropped, and no referer lands on the file's folder" do
      delete file_path(@file.node_id), headers: { "HTTP_REFERER" => "https://evil.example/files?folder=x" }
      assert_redirected_to files_path(folder: @laser.node_id)

      other = create_node!(@user, node_id: "n-other", name: "other.svg", kind: "file", parent_node_id: @laser.node_id)
      delete file_path(other.node_id)
      assert_redirected_to files_path(folder: @laser.node_id)
    end

    # A SAME-ORIGIN REFERER WHOSE PATH STARTS WITH "//" IS PROTOCOL-RELATIVE TO A BROWSER. Rails'
    # own guard raises OpenRedirectError on it -- a 500 after the delete already happened -- so
    # `safe_referer_path` drops it and the landing is the file's folder.
    test "a protocol-relative referer path is dropped, not raised on" do
      delete file_path(@file.node_id), headers: { "HTTP_REFERER" => "http://www.example.com//evil.example/x" }
      assert_redirected_to files_path(folder: @laser.node_id)
    end

    # A REFUSED DELETE SAYS SO IN WORDS AND STAYS PUT (UX audit D10). The port's own message is written
    # for a log — s3's names a raw node id and a copy cap, chunk_remote's the sync server's wire code —
    # so the sentence is the door's, and the maker is back on the page they pressed Delete on.
    test "a refused delete lands back where it was pressed, in a sentence with no port internals" do
      raw = "\"n-holder\" is 6000000000 bytes: over S3's 5GiB copy cap"
      from = files_path(folder: @laser.node_id)
      replacing(FileLayer.current, :delete, ->(*, **) { raise FileLayer::UnsupportedOperation, raw }) do
        delete file_path(@file.node_id), headers: referer(from)
      end

      assert_redirected_to from
      assert_equal "dice holder.lbrn2 couldn't be moved to Trash, and nothing was deleted.", flash[:alert]
      refute @user.nodes.find_by!(node_id: @file.node_id).deleted?
    end
  end
end
