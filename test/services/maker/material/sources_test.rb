require "test_helper"

module Maker
  module Material
    # WHERE PARTS COME FROM (spec 2026-11-22, "Adding parts, three ways"). Pinned to a fresh share
    # library, as every web-layer suite here is, so a library read is a real file read on every leg.
    class SourcesTest < ActiveSupport::TestCase
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "sources-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
      end

      # The house stub helper (Minitest 6 has no Object#stub).
      def replacing(owner, name, replacement)
        mod = owner.singleton_class
        own = mod.instance_methods(false).include?(name)
        original = mod.instance_method(name)
        mod.define_method(name, &replacement)
        yield
      ensure
        own ? mod.define_method(name, original) : mod.remove_method(name)
      end

      def fixture_path(name) = Rails.root.join("test/fixtures/files", name)

      def upload(name, from: name) = Rack::Test::UploadedFile.new(fixture_path(from), "application/octet-stream", original_filename: name)

      # A library file with REAL bytes: create_node! writes a placeholder, so overwrite it.
      def place!(name, from: name, parent: nil, user: @user)
        node = create_node!(user, node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent&.node_id,
                                  content_hash: SecureRandom.hex(8))
        @root.join(node.storage_path).binwrite(File.binread(fixture_path(from)))
        node
      end

      def dir!(name, parent: nil, user: @user)
        create_node!(user, node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent&.node_id)
      end

      def sizes(added) = added.parts.map { |p| [ p.name, p.page, p.width, p.height, p.reason ] }

      test "an upload is measured from its bytes; one it cannot measure says why" do
        added = Sources.uploads([ upload("plate.svg"), upload("bracket.stl", from: "plate.svg") ])
        assert_equal [ "plate.svg", nil, 80.0, 40.0, nil ], sizes(added).first
        assert_equal Maker::Previews::Dimensions::UNSUPPORTED, added.parts.second.reason
        assert_empty added.notes
      end

      test "a multi-page upload is one part per page that has something on it" do
        added = Sources.uploads([ upload("pages.lbrn2") ])
        assert_equal [ [ "pages.lbrn2", "Page 1", 205.0, 50.0, nil ], [ "pages.lbrn2", "Back", 50.0, 50.0, nil ] ], sizes(added)
      end

      test "one upload batch measures at most 20 files and says what it left out" do
        added = Sources.uploads(Array.new(23) { |i| upload("p#{i}.svg", from: "plate.svg") })
        assert_equal 20, added.parts.size
        assert_equal [ "Left out 3 files: one upload measures at most 20." ], added.notes
      end

      test "an upload over the byte limit is refused without being read" do
        file = upload("plate.svg")
        def file.read(*) = raise("read an oversized upload")
        replacing(Sources, :max_bytes, -> { 10 }) do
          assert_match(/\Aover the 10 Bytes limit\z/, Sources.uploads([ file ]).parts.first.reason)
        end
      end

      test "a folder adds its flat files, subfolders included, by name, and nothing else" do
        laser = dir!("laser")
        sub = dir!("lids", parent: laser)
        place!("plate.svg", parent: laser)
        place!("a-plate.dxf", from: "plate.dxf", parent: sub)
        place!("bracket.stl", from: "plate.svg", parent: laser)

        added = Sources.folder(@user, laser.node_id)
        assert_equal [ [ "a-plate.dxf", nil, 80.0, 40.0, nil ], [ "plate.svg", nil, 80.0, 40.0, nil ] ], sizes(added)
      end

      test "a folder past the cap adds the first 200 by name and says so" do
        replacing(Sources, :max_folder_files, -> { 1 }) do
          laser = dir!("laser")
          place!("b.svg", from: "plate.svg", parent: laser)
          place!("a.svg", from: "plate.svg", parent: laser)
          added = Sources.folder(@user, laser.node_id)
          assert_equal [ "a.svg" ], added.parts.map(&:name)
          assert_equal [ "Added the first 1 of 2 files from laser." ], added.notes
        end
      end

      test "a project adds its ATTACHED flat files only" do
        project = @user.maker_projects.create!(name: "Desk Lamp")
        attached = place!("plate.svg")
        place!("loose.svg", from: "plate.svg")
        @user.maker_file_attachments.create!(attachable: project, node_id: attached.node_id)

        assert_equal [ "plate.svg" ], Sources.project(@user, project.id).parts.map(&:name)
      end

      test "another user's project, folder or file answers like a missing one" do
        other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: "correct horse battery staple",
                             confirmed_at: Time.current)
        project = other.maker_projects.create!(name: "Theirs")
        folder = dir!("theirs", user: other)
        file = place!("theirs.svg", from: "plate.svg", user: other)

        assert_equal [ "Found no such project." ], Sources.project(@user, project.id).notes
        assert_equal [ "Found no such folder." ], Sources.folder(@user, folder.node_id).notes
        assert_equal [ "Found no such file." ], Sources.file(@user, file.node_id).notes
        [ Sources.project(@user, project.id), Sources.folder(@user, folder.node_id), Sources.file(@user, file.node_id) ]
          .each { |added| assert_empty added.parts }
      end

      # THE STORED SIZE IS USED WHEN ITS ROW IS CURRENT, AND ONLY THEN. The row below claims 12 x 34
      # while the bytes say 80 x 40, so which one comes back says which path ran.
      test "a library file's current thumbnail row is read instead of its bytes" do
        node = place!("plate.svg")
        token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
        row = @user.maker_previews.create!(node_id: node.node_id, version_id: token, kind: "thumbnail", status: "ready",
                                           renderer_revision: Maker::Previews::Svg::THUMBNAIL_REVISION,
                                           metadata: { "job" => { "width" => 12.0, "height" => 34.0 } })
        row.asset.attach(io: StringIO.new("\x89PNG".b), filename: "t.png", content_type: "image/png")

        assert_equal [ 12.0, 34.0 ], Sources.file(@user, node.node_id).parts.first.then { |p| [ p.width, p.height ] }

        row.update!(renderer_revision: 1) # an older build: its size, if any, is not this build's
        assert_equal [ 80.0, 40.0 ], Sources.file(@user, node.node_id).parts.first.then { |p| [ p.width, p.height ] }
      end

      test "an unreachable library is a reason on that part, never a 500" do
        node = place!("plate.svg")
        replacing(FileLayer.current, :read, ->(*, **) { raise FileLayer::FetchError, "unmounted" }) do
          assert_equal Sources::UNREACHABLE, Sources.file(@user, node.node_id).parts.first.reason
        end
      end

      # A STACK OVERFLOW IS NOT A `StandardError`, so "a reason, never a 500" has to name it.
      # `SvgGeometry` recurses once per nested `<g>`, and a request runs on a Puma THREAD, whose stack
      # is far smaller than the main thread's. So the measuring runs inside a Thread here. The first
      # assertion checks that this depth really does overflow a thread on this box, so the test
      # cannot pass over a file that never overflowed.
      test "an SVG nested deep enough to overflow a request thread is a reason, never a 500" do
        depth = 3000
        svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">) + ("<g>" * depth) +
              %(<rect width="5" height="5"/>) + ("</g>" * depth) + %(</svg>)
        overflowed = Thread.new do
          Maker::Previews::Dimensions.measure("deep.svg", svg)
          false
        rescue SystemStackError
          true
        end.value
        assert overflowed, "#{depth} nested groups no longer overflow a thread here; raise the depth"

        node = create_node!(@user, node_id: SecureRandom.uuid, name: "deep.svg", kind: "file", content_hash: SecureRandom.hex(8))
        @root.join(node.storage_path).binwrite(svg)
        upload = Rack::Test::UploadedFile.new(StringIO.new(svg), "image/svg+xml", original_filename: "deep.svg")
        reasons = Thread.new do
          [ Sources.uploads([ upload ]), Sources.file(@user, node.node_id) ].map { |added| added.parts.map(&:reason) }
        rescue SystemStackError => e
          e
        end.value

        assert_equal [ [ Sources::UNREADABLE ], [ Sources::UNREADABLE ] ], reasons
      end
    end
  end
end
