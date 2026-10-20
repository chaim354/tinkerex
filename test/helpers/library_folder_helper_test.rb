require "test_helper"

# The library's name on screen (J's three LIBRARY_HOST_PATH states, plus K's chosen folder). Display
# only: every value here is a sentence, escaped, and nothing opens it.
class LibraryFolderHelperTest < ActionView::TestCase
  include LibraryFolderHelper

  def with_host_path(value)
    had = ENV.key?("LIBRARY_HOST_PATH")
    was = ENV["LIBRARY_HOST_PATH"]
    value.nil? ? ENV.delete("LIBRARY_HOST_PATH") : ENV["LIBRARY_HOST_PATH"] = value
    yield
  ensure
    had ? ENV["LIBRARY_HOST_PATH"] = was : ENV.delete("LIBRARY_HOST_PATH")
  end

  test "the plain-text label has the same three states as the marked-up one" do
    with_host_path(nil) { assert_equal "The library folder on the server", library_folder_text }
    with_host_path("") { assert_equal "The folder your docker-compose.yml is in", library_folder_text }
    with_host_path(" /mnt/user/files ") { assert_equal "/mnt/user/files", library_folder_text }
  end

  test "with nothing chosen inside the mount, the root label is the mount's label" do
    with_host_path("") do
      assert_equal library_folder_label, library_root_label("")
      assert_equal library_folder_label, library_root_label(nil)
    end
  end

  test "a typed host path and the chosen folder read as one path" do
    with_host_path("/mnt/user/files/") do
      assert_dom_equal "<code>/mnt/user/files/Workshop/3d</code>", library_root_label("Workshop/3d")
    end
  end

  test "a prose label is followed by the chosen folder" do
    with_host_path(nil) do
      assert_dom_equal "The library folder on the server, in its folder <code>Workshop</code>",
                       library_root_label("Workshop")
    end
    with_host_path("") do
      assert_dom_equal "The folder your <code>docker-compose.yml</code> is in, in its folder <code>Workshop</code>",
                       library_root_label("Workshop")
    end
  end

  test "the chosen folder is escaped, never interpreted" do
    with_host_path(nil) do
      assert_includes library_root_label("<b>x</b>"), "&lt;b&gt;x&lt;/b&gt;"
    end
  end

  test "with no argument it reads the stored choice" do
    Setting.put(Tinkerex::LibraryRoot::KEY, "Workshop")
    with_host_path("/srv/lib") { assert_dom_equal "<code>/srv/lib/Workshop</code>", library_root_label }
  end
end
