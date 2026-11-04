require "test_helper"
require "support/mcp_client"

module Mcp
  # ON A FRESH SHARE LIBRARY, LIKE markdown_file_page_test.rb: the rows AND the bytes are this test's
  # own, so the three backend legs run the same tests and the RUN counts stay equal (§15).
  class LibraryToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    LIMIT = McpServer::Tools::Library::READ_LIMIT

    setup do
      @root = use_fresh_share_library!
      @token = bootstrap_token(email: "mcp-library@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-library@example.com")
      @projects = dir!("Projects", nil)
      @lamp = dir!("lamp", @projects)
      @readme = file!("README.md", @lamp, "# Lamp\n\nA desk lamp.\n")
      @lid = file!("lid.stl", @lamp, "solid lid")
      file!(".DS_Store", @lamp, "x")
      dir!("models", @lamp)
    end

    def dir!(name, parent)
      create_node!(@user, node_id: SecureRandom.uuid, name: name, kind: "dir",
                          parent_node_id: parent&.node_id, mtime: 1_700_000_000_000_000_000, size: 0)
    end

    # create_node! writes a placeholder at the storage_path it computes; the body goes over it.
    def file!(name, parent, body)
      node = create_node!(@user, node_id: SecureRandom.uuid, name: name, kind: "file", parent_node_id: parent&.node_id,
                                 mtime: 1_700_000_000_000_000_000, size: body.bytesize,
                                 content_hash: Digest::SHA256.hexdigest(body))
      @root.join(node.storage_path).binwrite(body)
      node
    end

    test "list_folder answers the root, then a folder with folders first, hidden files left out, paths and text flags" do
      out = mcp_structured(@token, "list_folder")
      assert_equal "", out["path"]
      assert_equal [ [ "Projects", "dir", "Projects" ] ], out["entries"].map { |e| [ e["name"], e["kind"], e["path"] ] }

      out = mcp_structured(@token, "list_folder", { path: "/Projects/lamp/" })
      assert_equal "Projects/lamp", out["path"]
      assert_equal %w[models README.md lid.stl], out["entries"].map { |e| e["name"] }
      readme = out["entries"].find { |e| e["name"] == "README.md" }
      assert_equal "Projects/lamp/README.md", readme["path"]
      assert_equal true, readme["text"]
      assert_equal false, out["entries"].last["text"]
      assert_equal "2023-11-14T22:13:20Z", readme["modified_at"]
      assert_equal @readme.node_id, readme["node_id"]
      assert_equal false, out["truncated"]
    end

    test "list_folder refuses a file, names a missing path, and refuses dot segments" do
      assert_match(/is a file/, mcp_refusal(@token, "list_folder", { path: "Projects/lamp/README.md" }))
      assert_equal "No file or folder at \"Projects/nope\".", mcp_refusal(@token, "list_folder", { path: "Projects/nope" })
      assert_match(/no "\." or "\.\." segments/, mcp_refusal(@token, "list_folder", { path: "Projects/../etc" }))
    end

    test "read_text_file answers the bytes of a text file as UTF-8" do
      out = mcp_structured(@token, "read_text_file", { path: "Projects/lamp/README.md" })
      assert_equal "# Lamp\n\nA desk lamp.\n", out["text"]
      assert_equal [ "Projects/lamp/README.md", @readme.node_id, 21 ], [ out["path"], out["node_id"], out["size"] ]
    end

    test "read_text_file refuses a folder, the root, a binary file, and a missing path" do
      assert_match(/is a folder/, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp" }))
      assert_match(/library root/, mcp_refusal(@token, "read_text_file", { path: "/" }))
      assert_equal "lid.stl is not text (its kind is Models); read_text_file only reads text files.",
                   mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/lid.stl" })
      assert_equal "No file or folder at \"Projects/lamp/x.md\".", mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/x.md" })
    end

    test "read_text_file refuses a file over the cap BEFORE reading it, and one that grew past it after" do
      big = file!("big.txt", @lamp, "x" * (LIMIT + 1))
      replacing(FileLayer.current, :read, ->(*, **) { flunk "read must not run for a file the catalog already knows is too big" }) do
        assert_match(/#{LIMIT + 1} bytes/, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/big.txt" }))
      end
      big.update_column(:size, 10)
      assert_match(/bytes/, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/big.txt" }))
    end

    test "read_text_file answers the unreachable sentence when the store is down, and scrubs bad UTF-8" do
      replacing(FileLayer.current, :read, ->(*, **) { raise FileLayer::FetchError, "mount gone" }) do
        assert_equal McpServer::Tool::UNREACHABLE, mcp_refusal(@token, "read_text_file", { path: "Projects/lamp/README.md" })
      end
      file!("notes.txt", @lamp, "ok \xFF bad".b)
      assert_equal "ok � bad", mcp_structured(@token, "read_text_file", { path: "Projects/lamp/notes.txt" })["text"]
    end

    test "search answers files, folders, projects and inventory in one call, with paths" do
      @user.maker_projects.create!(name: "Lamp stand")
      @user.maker_inventory_items.create!(name: "Lamp cord")
      out = mcp_structured(@token, "search", { q: "LAMP" })
      assert_equal [ "Projects/lamp" ], out["folders"].map { |f| f["path"] }
      assert_equal [], out["files"]
      assert_equal [ "lamp-stand" ], out["projects"].map { |p| p["slug"] }
      assert_equal [ "Lamp cord" ], out["inventory"].map { |i| i["name"] }

      out = mcp_structured(@token, "search", { q: "lid" })
      assert_equal [ "Projects/lamp/lid.stl" ], out["files"].map { |f| f["path"] }
      assert_equal "lid", out["q"]
    end
  end
end
