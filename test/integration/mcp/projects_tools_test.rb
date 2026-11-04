require "test_helper"
require "support/mcp_client"

module Mcp
  class ProjectsToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      # create_project mints Projects/<slug> THROUGH THE PORT -- a real mkdir. On a root this test
      # owns it is the same on every backend leg; on the ambient adapter it is Forbidden on s3 and
      # a provisioning call on chunk_remote (project-folder fixtures must be port-free otherwise).
      @root = use_fresh_share_library!
      @token = bootstrap_token(email: "mcp-projects@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-projects@example.com")
    end

    test "create_project derives the slug, makes the folder and answers its path" do
      out = mcp_structured(@token, "create_project", { name: "Desk Lamp", kind: "laser", description: "A lamp" })
      assert_equal "desk-lamp", out["slug"]
      assert_equal "Projects/desk-lamp", out["folder"]
      assert_equal "laser", out["kind"]
      assert_equal "A lamp", out["description"]
      assert_nil out["note"]
      project = @user.maker_projects.find_by!(slug: "desk-lamp")
      assert @user.nodes.present.find_by(node_id: project.folder_node_id, kind: "dir")
    end

    test "create_project still creates the project when the library is unreachable, and says so" do
      replacing(FileLayer.current, :mkdir, ->(*, **) { raise FileLayer::FetchError, "mount gone" }) do
        out = mcp_structured(@token, "create_project", { name: "Offline" })
        assert_equal "offline", out["slug"]
        assert_nil out["folder"]
        assert_match(/could not be reached/, out["note"])
      end
      assert @user.maker_projects.find_by(slug: "offline")
    end

    test "create_project refuses a blank name as a validation message, not a crash" do
      message = mcp_refusal(@token, "create_project", { name: "   " })
      assert_match(/Name can't be blank/, message)
    end

    test "list_projects lists newest change first with folder path and open task count, and filters" do
      lamp = @user.maker_projects.create!(name: "Lamp", status: "active")
      project_folder_rows!(@user, lamp)
      @user.maker_tasks.create!(taskable: lamp, title: "Cut base")
      @user.maker_tasks.create!(taskable: lamp, title: "Done one", status: "done")
      @user.maker_projects.create!(name: "Old box", status: "done")

      out = mcp_structured(@token, "list_projects")
      assert_equal %w[old-box lamp], out["projects"].map { |p| p["slug"] }
      row = out["projects"].find { |p| p["slug"] == "lamp" }
      assert_equal "Projects/lamp", row["folder"]
      assert_equal 1, row["open_tasks"]
      assert_equal false, out["truncated"]

      assert_equal [ "lamp" ], mcp_structured(@token, "list_projects", { status: "active" })["projects"].map { |p| p["slug"] }
      assert_equal [ "old-box" ], mcp_structured(@token, "list_projects", { q: "BOX" })["projects"].map { |p| p["slug"] }
    end

    test "list_projects is capped and says so" do
      (McpServer::Tool::LIST_CAP + 1).times { |i| @user.maker_projects.create!(name: "P#{i}") }
      out = mcp_structured(@token, "list_projects")
      assert_equal McpServer::Tool::LIST_CAP, out["projects"].size
      assert_equal true, out["truncated"]
    end

    test "get_project answers tasks open first, the build log newest first, BOMs and attached files" do
      lamp = @user.maker_projects.create!(name: "Lamp", description: "RGB")
      folder = project_folder_rows!(@user, lamp)
      done = @user.maker_tasks.create!(taskable: lamp, title: "Done", status: "done", position: 0)
      open = @user.maker_tasks.create!(taskable: lamp, title: "Open", status: "todo", position: 1)
      lamp.build_log_entries.create!(user: @user, body: "first", logged_at: 2.days.ago)
      lamp.build_log_entries.create!(user: @user, body: "second", logged_at: 1.day.ago)
      bom = lamp.boms.create!(user: @user)
      bom.lines.create!(user: @user, part_name: "M3 bolt", quantity: 4)
      file = @user.nodes.create!(node_id: SecureRandom.uuid, name: "lid.stl", kind: "file",
                                 parent_node_id: folder.node_id, mtime: 1, size: 10)
      lamp.file_attachments.create!(user: @user, node_id: file.node_id, role: "model", label: "Lid")

      out = mcp_structured(@token, "get_project", { slug: "lamp" })
      assert_equal "RGB", out["description"]
      assert_equal [ open.id, done.id ], out["tasks"].map { |t| t["id"] }
      assert_equal %w[second first], out["build_log"].map { |e| e["body"] }
      assert_equal [ { "id" => bom.id, "name" => "BOM", "revision" => 1, "lines" => 1 } ], out["boms"]
      assert_equal [ "Projects/lamp/lid.stl" ], out["files"].map { |f| f["path"] }
      assert_equal "Lid", out["files"].first["label"]
    end

    test "get_project names a missing slug" do
      assert_equal "No project \"nope\".", mcp_refusal(@token, "get_project", { slug: "nope" })
    end

    test "update_project changes only the given fields, archives and unarchives" do
      lamp = @user.maker_projects.create!(name: "Lamp", description: "keep", status: "active")
      out = mcp_structured(@token, "update_project", { slug: "lamp", name: "Desk lamp" })
      assert_equal "Desk lamp", out["name"]
      assert_equal "keep", lamp.reload.description

      out = mcp_structured(@token, "update_project", { slug: "lamp", status: "archived" })
      assert_equal "archived", out["status"]
      assert lamp.reload.archived_at.present?
      assert_equal lamp.archived_at.utc.iso8601, out["archived_at"]

      mcp_structured(@token, "update_project", { slug: "lamp", status: "active" })
      assert_nil lamp.reload.archived_at
    end

    test "a misspelt argument is refused by the schema, never a crash" do
      message = mcp_refusal(@token, "get_project", { slugg: "lamp" })
      assert_match(/slugg|additional property|Missing required/, message)
    end
  end
end
