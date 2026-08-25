require "test_helper"

module Maker
  module Addons
    class LibraryOutputTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @user = User.create!(email: "lo-#{SecureRandom.hex(4)}@example.com")
        if ENV["LIBRARY_BACKEND"] == "s3"
          require_relative "../../../support/fake_s3"
          @fake = FakeS3.new
          FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                                secret_access_key: "sk", prefix: "library",
                                                client: @fake.client)
        end
      end
      teardown { FileLayer.reset! }

      test "writes a bundle of mixed-type files and ties each to the state" do
        state = @user.maker_addon_states.create!(addon_key: "boxes", name: "Box A", data: {})
        # `thumbnail` is deliberately a role NO ADDON EMITS. The point of this test is that
        # LibraryOutput is role-agnostic — it never inspects the bytes or the role — and a role the
        # app has never heard of proves that better than a real one, which could pass by coincidence.
        # (It used to be `parameters`, back when every addon wrote a `.params.json` beside its output.
        # That file was removed 2026-07-29 — `Maker::AddonState#data` is the record — so keeping the
        # word here would have left a fixture naming a concept the app no longer has.)
        files = [
          { name: "boxa.svg", bytes: "<svg/>".b, content_type: "image/svg+xml", role: "output" },
          { name: "boxa-thumb.png", bytes: "\x89PNG".b, content_type: "image/png", role: "thumbnail" }
        ]

        result = Maker::Addons::LibraryOutput.write(user: @user, state:, parent_node_id: nil, files:)

        assert_equal 2, result.length
        state.reload
        assert_equal %w[output thumbnail], state.files.map(&:role)
        state.files.each do |af|
          assert @user.nodes.exists?(node_id: af.node_id), "node #{af.node_id} must exist in the library"
        end
        assert_operator enqueued_jobs.count { |j| j[:job] == Maker::GeneratePreviewJob }, :>=, 1
      end

      # PER-FILE DESTINATION, because one save can collide on some outputs and not others. The
      # boxes addon emits `<base>.svg` AND `<base>-plan.svg` in a single save; a re-save can find
      # the first name taken in its category folder and the second free. A single
      # `parent_node_id:` for the whole call cannot express that, so a file may carry its own —
      # the method's argument stays the DEFAULT, which is what every caller before this used.
      #
      # THE DOOR RESOLVES IT, NOT THIS CLASS. Which folder a name belongs in is project policy
      # (Maker::ProjectFolders), and LibraryOutput is the backend-neutral WRITE path — it never
      # inspects the bytes and must not start inspecting the names either.
      test "a file may name its own destination, overriding the call's default" do
        state = @user.maker_addon_states.create!(addon_key: "boxes", name: "Box B", data: {})
        design = Maker::LibraryFolder.ensure_path!(@user, [ "design" ])

        result = Maker::Addons::LibraryOutput.write(
          user: @user, state:, parent_node_id: nil,
          files: [ { name: "root.svg", bytes: "<svg/>".b, content_type: "image/svg+xml", role: "output" },
                   { name: "filed.svg", bytes: "<svg/>".b, content_type: "image/svg+xml",
                     role: "output", parent_node_id: design.node_id } ]
        )

        by_name = result.to_h { |af| [ @user.nodes.find_by(node_id: af.node_id).name, af ] }
        assert_nil @user.nodes.find_by(node_id: by_name["root.svg"].node_id).parent_node_id
        assert_equal design.node_id,
                     @user.nodes.find_by(node_id: by_name["filed.svg"].node_id).parent_node_id
      end

      # THE OVERWRITE ITSELF, and node_id is the assertion that matters — the same §14a landmine
      # the port's own contract test guards, one layer up. On chunk this is a new VERSION against
      # the existing node (base_version_id = its current), which is what versioning is for and
      # touches the port not at all; on share/s3 it is FileLayer#write(replace: true). Backend-
      # neutral by construction, and this test runs on all three legs.
      # TWO STATES, ONE PER SAVE, because that is what the door does — Tools::AddonsController
      # #create mints a fresh Maker::AddonState every time. It also has to: maker_addon_files is
      # UNIQUE on (addon_state_id, node_id), so a second write of the same node under the SAME
      # state raises RecordNotUnique. Found by writing this test with one state and watching it
      # error — worth recording, because reusing the state here would have been the natural way to
      # write it and would have failed for a reason that says nothing about replace.
      test "replace rewrites the file already at that name, keeping its node" do
        first = Maker::Addons::LibraryOutput.write(
          user: @user, state: @user.maker_addon_states.create!(addon_key: "boxes", name: "Box C1", data: {}),
          parent_node_id: nil,
          files: [ { name: "iter.svg", bytes: "<svg>v1</svg>".b, content_type: "image/svg+xml", role: "output" } ]
        ).sole

        second = Maker::Addons::LibraryOutput.write(
          user: @user, state: @user.maker_addon_states.create!(addon_key: "boxes", name: "Box C2", data: {}),
          parent_node_id: nil,
          files: [ { name: "iter.svg", bytes: "<svg>v2</svg>".b, content_type: "image/svg+xml",
                     role: "output", replace: true } ]
        ).sole

        assert_equal first.node_id, second.node_id,
                     "a replace must reuse the node — a new node_id orphans every attachment (§14a)"
        assert_equal 1, @user.nodes.present.where(name: "iter.svg", parent_node_id: nil).count,
                     "one live node at that name, not a second beside it"
        assert_equal "<svg>v2</svg>", FileLayer.current.read(@user, node_id: first.node_id)
      end
    end
  end
end
