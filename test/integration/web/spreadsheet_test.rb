require "test_helper"
require "support/xlsx_fixture"
require "support/git_repo_fixture"
require "support/fake_s3"
require "support/chunk_remote_journey"

module Web
  # THE WORKBOOK VIEWER'S DOOR (2026-10-21): the file page offers the grid, GET hands it the
  # workbook, PATCH writes a list of edits back to the SAME node. Three classes, one per backend, so
  # each backend's write path is driven through the real controller: share (a fresh library, pinned
  # so the three CI legs run these identically), s3 (FakeS3 under the real adapter), and chunk_remote
  # (the real sync server, skipped where none is configured — the journey rig's own rule).
  class SpreadsheetShareTest < ActionDispatch::IntegrationTest
    include XlsxFixture
    include GitRepoFixture

    PASSWORD = "correct horse battery staple".freeze

    setup do
      library_root
      @user = User.create!(email: "xlsx-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def set(row, col, value, sheet: 0) = { sheet:, op: "set", row:, col:, value: }
    def save!(node, ops, token: token_for(node)) = patch(file_spreadsheet_path(node.node_id), params: { base_token: token, ops: }, as: :json)
    def grid(bytes) = Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(bytes)).payload[:sheets].first

    # GitRepoFixture#seed_plain_file! writes text; a workbook is a zip, so it goes down in binary.
    def seed_xlsx!(name, bytes, dir: "Loose")
      FileUtils.mkdir_p(File.join(library_root, dir))
      File.binwrite(File.join(library_root, dir, name), bytes)
      Library::ScanJob.new.perform(user_id: @user.id)
      @user.nodes.present.find_by!(name:, kind: "file")
    end

    test "an xlsx file page renders the grid, its two doors and the no-history note" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes)

      get file_path(node.node_id)

      assert_response :success
      assert_select ".spreadsheet[data-controller=spreadsheet]" do |el|
        assert_equal file_spreadsheet_path(node.node_id), el.first["data-spreadsheet-url-value"]
        assert_equal file_spreadsheet_path(node.node_id), el.first["data-spreadsheet-save-url-value"]
        assert_match %r{/assets/jspreadsheet-\h+\.js}, el.first["data-spreadsheet-scripts-value"]
      end
      assert_select ".spreadsheet .no-history-note", text: /keeps no history/
      assert_select "[data-controller~=editor], [data-controller~=codeview]", 0, "a workbook is not source text"
    end

    test "GET answers the workbook and the token it was read at" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes)

      get file_spreadsheet_path(node.node_id), as: :json

      assert_response :success
      body = response.parsed_body
      assert_equal token_for(node), body["content_token"]
      assert_equal %w[Parts Notes], body["sheets"].map { |s| s["name"] }
      assert_equal "Bolt M3", body["sheets"][0]["rows"][1][0]
    end

    # `replace: true` REUSES THE NODE (§14a): a delete-then-create passes every bytes-oriented check
    # while orphaning each attachment, BOM line and tag keyed on the node id, silently.
    test "a save rewrites the same node, and the parts nobody touched come back unchanged" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes)
      before = xlsx_entries(read_back(node))

      save!(node, [ set(1, 1, "12"), set(3, 0, "Spacer 6mm") ])

      assert_response :success
      assert_equal token_for(node), response.parsed_body["content_token"]
      assert_equal 1, @user.nodes.present.where(name: "bom.xlsx").count
      assert_equal node.node_id, @user.nodes.present.find_by!(name: "bom.xlsx").node_id
      after = read_back(node)
      rows = grid(after)[:rows]
      assert_equal "12", rows[1][1]
      assert_equal "Spacer 6mm", rows[3][0]
      %w[xl/styles.xml xl/sharedStrings.xml xl/worksheets/sheet2.xml].each do |part|
        assert_equal before[part], xlsx_entries(after)[part], "#{part} changed"
      end
    end

    test "a stale token is refused with the reload sentence and writes nothing" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes)
      original = read_back(node)

      save!(node, [ set(1, 1, "12") ], token: "stale")

      assert_response :conflict
      assert_equal Maker::TextSave::STALE, response.parsed_body["error"]
      assert_equal original, read_back(node)
    end

    # THE STORE ARM: the catalog still agrees (no scan since the desktop edit), so only the port's
    # `expect_token:` comparison against the bytes on disk can refuse — Maker::TextSave's header.
    test "a desktop edit the catalog has not seen yet is refused, not overwritten" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes)
      token = token_for(node)
      desktop = xlsx_bytes(notes_sheet: notes_sheet_xml(rows: %(<row r="1"><c r="A1" t="inlineStr"><is><t>edited in Excel</t></is></c></row>)))
      assert_not_equal read_back(node), desktop, "the desktop edit must really change the bytes"
      File.binwrite(File.join(library_root, "Loose", "bom.xlsx"), desktop)

      save!(node, [ set(1, 1, "12") ], token:)

      assert_response :conflict
      assert_equal desktop, File.binread(File.join(library_root, "Loose", "bom.xlsx"))
    end

    test "an operation the workbook cannot take is refused with its reason" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes)

      save!(node, [ { sheet: 0, op: "insert_rows", at: 1, count: 1 } ])

      assert_response :unprocessable_entity
      assert_match(/Excel extensions/, response.parsed_body["error"])
    end

    test "rows inserted on a plain sheet reach the file" do
      node = seed_xlsx!("bom.xlsx", xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false)))

      save!(node, [ { sheet: 0, op: "insert_rows", at: 3, count: 1 }, set(3, 0, "Washer") ])

      assert_response :success
      rows = grid(read_back(node))[:rows]
      assert_equal [ "Nut M3", "Washer", "Spacer 5mm" ], rows[2..4].map(&:first)
    end

    test "a file that is not a readable workbook says so" do
      node = seed_xlsx!("broken.xlsx", "not a zip at all")

      get file_spreadsheet_path(node.node_id), as: :json

      assert_response :unprocessable_entity
      assert_match(/not a readable \.xlsx/, response.parsed_body["error"])
    end

    test "another user's workbook and a file that is not a workbook have no door" do
      mine = seed_plain_file!("notes.txt", "hello")
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.xlsx", kind: "file")

      get file_spreadsheet_path(mine.node_id), as: :json
      assert_response :not_found
      get file_spreadsheet_path(theirs.node_id), as: :json
      assert_response :not_found
      patch file_spreadsheet_path(theirs.node_id), params: { base_token: "x", ops: [ set(0, 0, "x") ] }, as: :json
      assert_response :not_found
    end

    # INSIDE A WORKING TREE THE SAVE IS A PENDING EDIT FOR THE COMMIT BOX, through Maker::TextSave
    # like every edit there (git-editing.md), and the bytes still go through the port.
    test "a workbook inside a git working tree records a pending edit" do
      make_repo!(name: "lamp", files: { "README.md" => "lamp\n" })
      node = seed_xlsx!("bom.xlsx", xlsx_bytes, dir: "lamp")

      save!(node, [ set(1, 1, "12") ])

      assert_response :success
      assert_equal 1, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count
    end
  end

  class SpreadsheetS3Test < ActionDispatch::IntegrationTest
    include XlsxFixture

    PASSWORD = "correct horse battery staple".freeze
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "xlsx-s3-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
      sign_in_web!(@user, password: PASSWORD)
      @fake.seed!("#{PREFIX}/bom.xlsx", xlsx_bytes, last_modified: Time.now)
      Library::S3Observer.call(@user, adapter: FileLayer.current, max_delete_pct: 100)
      @node = @user.nodes.find_by!(storage_path: "bom.xlsx")
    end

    def token = FileLayer.current.stat(@user, node_id: @node.node_id).content_token

    test "a save on s3 writes the object in place and keeps the node" do
      patch file_spreadsheet_path(@node.node_id),
            params: { base_token: token, ops: [ { sheet: 0, op: "set", row: 1, col: 1, value: "12" } ] }, as: :json

      assert_response :success
      body = @fake.objects["#{PREFIX}/bom.xlsx"].body
      assert_equal "12", Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(body)).payload[:sheets][0][:rows][1][1]
      assert_equal @node.node_id, @user.nodes.present.find_by!(storage_path: "bom.xlsx").node_id
    end

    test "an object changed in the bucket since the page loaded is refused" do
      stale = token
      changed = xlsx_bytes(notes_sheet: notes_sheet_xml(rows: %(<row r="1"><c r="A1" t="inlineStr"><is><t>edited in the bucket</t></is></c></row>)))
      assert_not_equal @fake.objects["#{PREFIX}/bom.xlsx"].body, changed
      @fake.seed!("#{PREFIX}/bom.xlsx", changed, last_modified: Time.now)

      patch file_spreadsheet_path(@node.node_id),
            params: { base_token: stale, ops: [ { sheet: 0, op: "set", row: 1, col: 1, value: "12" } ] }, as: :json

      assert_response :conflict
      assert_equal changed, @fake.objects["#{PREFIX}/bom.xlsx"].body
    end
  end

  class SpreadsheetChunkRemoteTest < ActionDispatch::IntegrationTest
    include XlsxFixture
    include ChunkRemoteJourney

    setup { skip_unless_remote_server }

    # chunk_remote is not port_writable: the save is the two-phase commit LibraryOutput drives
    # server-side, against the node's current version, so the sync server records a conflict on a
    # stale base rather than overwriting (§6). The bytes carry the prefix so the content-addressed
    # store sees new chunks on every run (the journey rig's upload note).
    test "a save on chunk_remote commits a new version of the same node" do
      user = sign_in
      bytes = xlsx_bytes(notes_sheet: notes_sheet_xml(rows: %(<row r="1"><c r="A1" t="inlineStr"><is><t>#{journey_prefix}</t></is></c></row>)))
      node_id = upload_through_ui("#{journey_prefix}-bom.xlsx", bytes)
      token = FileLayer.current.stat(user, node_id:).content_token

      get file_spreadsheet_path(node_id), as: :json
      assert_response :success
      assert_equal token, response.parsed_body["content_token"]

      patch file_spreadsheet_path(node_id),
            params: { base_token: token, ops: [ { sheet: 0, op: "set", row: 1, col: 1, value: "12" } ] }, as: :json

      assert_response :success, response.body
      after = FileLayer.current.read(user, node_id:)
      assert_equal "12", Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(after)).payload[:sheets][0][:rows][1][1]
      assert_not_equal token, FileLayer.current.stat(user, node_id:).content_token, "a new version"
      assert_equal 1, user.nodes.present.where(name: "#{journey_prefix}-bom.xlsx").count
    end
  end
end
