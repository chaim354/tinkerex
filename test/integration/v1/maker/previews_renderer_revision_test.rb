require "test_helper"

module V1
  module Maker
    # THE v1 ENQUEUE DOOR DELEGATES TO `Maker::Previews::Enqueue`, AND THESE ARE THE AXES IT USED
    # TO BE MISSING.
    #
    # `#create` inlined its own two-axis lifecycle (`version_id` and `failed`) until 2026-08-19.
    # It wrote `version_id` and left `renderer_revision` at the column default of 1, so a row born
    # through this door for any file whose renderer declares more than 1 — `.stl` and `.3mf` at 2,
    # `.lbrn2` and `.mage` at 4 — was stale by construction: the job then rendered with current
    # code and marked it `ready`, and every reader that compares revisions judged a correct,
    # current artifact stale and re-enqueued it, forever. Silent on both sides.
    #
    # WHY THIS FILE AND NOT `enqueue_test.rb`: the service has always been right. What was wrong
    # was that the API did not call it, and only a test that drives the real request can see that
    # (§14e — "the suite being green is not evidence a guard works if the guard's precondition is
    # never established in test"). `previews_test.rb` cannot: every `node_id` in it is
    # name-shaped (`n1.svg`, `here.svg`, `ready.svg`) AND `.svg` declares revision 1, so the
    # column default happens to be correct there and the whole file stays green over the bug.
    class PreviewsRendererRevisionTest < ActionDispatch::IntegrationTest
      # A UUID, WHICH IS WHAT A REAL DEVICE ACTUALLY SENDS (§5: "stable cross-device ids are string
      # UUIDs"), and the only shape that can catch the name-ladder shortcut. Resolving the name as
      # `filename || node_id` passes this UUID to the job as an EXPLICIT filename, which outranks
      # the job's own node lookup — so every real synced file would resolve to no renderer and be
      # marked `unsupported`. A name-shaped node_id hides that completely.
      UUID = "6f2a1c3e-0b47-4d51-9a8e-2c7b5d0f1e93".freeze

      setup do
        Sync::Storage::ChunkStore.reset!
        @token = bootstrap_token(email: "rev@example.com", device_name: "laptop")
        @user  = User.find_by(email: "rev@example.com")
      end

      def auth(t) = { "Authorization" => "Bearer #{t}" }

      # BOTH content columns carry the posted version, so `refuse_stale_version!` sees a match on
      # every backend rather than only one: chunk's `content_token` is `current_version_id`,
      # share's and s3's is `content_hash`. That is what lets this file run unpinned.
      def synced_node(name:, node_id: UUID, version: "v1")
        @user.nodes.create!(node_id: node_id, name: name, kind: "file", deleted: false,
                            current_version_id: version, content_hash: version)
      end

      def existing_preview(status:, revision:, node_id: UUID, version: "v1")
        @user.maker_previews.create!(node_id: node_id, kind: "thumbnail", version_id: version,
                                     status: status, renderer_revision: revision)
      end

      def post_preview(node_id: UUID, version_id: "v1", **extra)
        post "/v1/maker/previews",
             params: { preview: { node_id: node_id, version_id: version_id }.merge(extra) },
             as: :json, headers: auth(@token)
      end

      # (a) THE ASSERTION THAT FAILS ON THE CODE THIS FIX REPLACED — `1 != 2`.
      #
      # Asserted against the renderer's OWN constant, never the literal 2: pinning the number here
      # would make this guard rot silently at the next bump, which is the exact class of bug it
      # exists to catch.
      test "a .stl row is born at the STL renderer's revision, not the column default" do
        synced_node(name: "part.stl")

        post_preview
        assert_response :created

        assert_operator ::Maker::Previews::Stl::THUMBNAIL_REVISION, :>,
                        ::Maker::Previews::Enqueue::BASE_REVISION,
                        "this guard only carries weight while Stl declares above the column default"
        assert_equal ::Maker::Previews::Stl::THUMBNAIL_REVISION,
                     @user.maker_previews.sole.renderer_revision
      end

      # (b) THE `rebuilt` AXIS, WHICH THE API DID NOT HAVE AT ALL — and it could not be reached by
      # the `version_id` axis either, because a finished design's content never changes.
      test "a renderer bump re-enqueues through the API and does NOT blank the ready artifact" do
        synced_node(name: "part.stl")
        current = ::Maker::Previews::Stl::THUMBNAIL_REVISION
        row = existing_preview(status: "ready", revision: current - 1)

        assert_enqueued_with(job: ::Maker::GeneratePreviewJob) { post_preview }
        assert_response :ok

        assert_equal current, row.reload.renderer_revision
        # §14h: A CONTENT REPOINT BLANKS THE ARTIFACT; A RENDERER REBUILD DOES NOT. This is the
        # observable wire change — the API used to answer a fresh `pending` here.
        assert_equal "ready", row.status
        assert_equal "ready", JSON.parse(response.body)["status"]
      end

      # (c) THE `stalled` AXIS. `processing` is an ASSERTION that a job exists; nothing else ever
      # verifies it, so before this a row wedged by a lost job was unrecoverable through v1.
      #
      # THE ROW MUST BE AGED EXPLICITLY. A test that merely re-POSTs a freshly created `processing`
      # row can never fail, whatever the code does — §15's timestamp trap, one axis over.
      test "a processing row stalled past the window is healed through the API" do
        synced_node(name: "part.stl")
        row = existing_preview(status: "processing",
                               revision: ::Maker::Previews::Stl::THUMBNAIL_REVISION)
        row.update_column(:updated_at, ::Maker::Previews::Enqueue::STALLED_AFTER.ago - 1.minute)

        assert_enqueued_with(job: ::Maker::GeneratePreviewJob) { post_preview }
        assert_response :ok
      end

      # The other half, and it is a SEPARATE assertion on purpose: deleting the window entirely
      # (re-enqueue any `processing` row) leaves the test above green while turning every poll into
      # a duplicate job.
      test "a processing row inside the window is left alone" do
        synced_node(name: "part.stl")
        existing_preview(status: "processing",
                         revision: ::Maker::Previews::Stl::THUMBNAIL_REVISION)

        assert_no_enqueued_jobs(only: ::Maker::GeneratePreviewJob) { post_preview }
        assert_response :ok
      end

      # THE LADDER'S FIRST RUNG. Distinguished by revision rather than by "did it work", because
      # `.svg` declares 1 — the same value as the column default — so a node named `drawing.svg`
      # and a broken ladder are indistinguishable unless the explicit name is the one above it.
      test "an explicit filename outranks the node's own name" do
        synced_node(name: "drawing.svg")

        post_preview(filename: "part.stl")
        assert_response :created
        assert_equal ::Maker::Previews::Stl::THUMBNAIL_REVISION,
                     @user.maker_previews.sole.renderer_revision
      end

      # (d) THE ONE POLICY THIS DOOR DOES NOT SHARE WITH THE EAGER CALLERS — `skip_unrenderable:
      # false`. An API client polls, so it must get a row even for a name no renderer handles; the
      # terminal `unsupported` is the JOB's to write, because only the job can tell "no renderer
      # for this type" from "toolchain missing on this box".
      test "a name no renderer handles still yields a pollable row at the base revision" do
        synced_node(name: "part.sldprt")

        assert_enqueued_with(job: ::Maker::GeneratePreviewJob) { post_preview }
        assert_response :created

        row = @user.maker_previews.sole
        assert_equal "pending", row.status
        assert_equal ::Maker::Previews::Enqueue::BASE_REVISION, row.renderer_revision
      end
    end
  end
end
