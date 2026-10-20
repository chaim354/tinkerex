require "test_helper"

module Maker
  module Previews
    class ThumbnailMapTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      # A minimal FileLayer stand-in: ThumbnailMap only calls stat_all, so a duck-typed fake lets
      # us drive the token/preview resolution + the degrade path without a real backend. This is
      # the same `FileLayer.current = …` seam the share/s3 web tests use.
      #
      # IT ANSWERS WITH THE REAL `FileLayer::FileInfo`, not a Struct of the two fields we happen to
      # read. The map now reads `name` and `kind` off the port's answer as well as `content_token`,
      # and a hand-rolled stand-in is exactly the shape §14e warns about — a fake that shares the
      # code's understanding of the wire confirms it rather than testing it. All three adapters
      # build this Data class, so a change to it fails here rather than in production.
      class FakeLayer
        def initialize(result) = (@result = result)

        def stat_all(_user, node_ids:)
          raise @result if @result.is_a?(StandardError)
          @result.slice(*node_ids)
        end
      end

      def info(node_id, name: "part.stl", kind: "file", token: "tok-1")
        FileLayer::FileInfo.new(node_id:, name:, kind:, size: 1, mtime: 1, content_token: token)
      end

      def serve(*infos)
        FileLayer.current = FakeLayer.new(infos.to_h { |i| [ i.node_id, i ] })
      end

      # The renderer's CURRENT revision for a name, asked of the code rather than written down.
      # `.lbrn2` is at 4 and `.stl` at 2 today; a literal here would pin this test to whichever
      # number a renderer happens to be on and go red on the next legitimate bump, which is the
      # opposite of what it is for. §14h pins the ThreeMf/Stl pair as a RELATIONSHIP for the same
      # reason.
      def revision_of(name) = Maker::Previews::Enqueue.revision_for_name(name, "thumbnail")

      setup do
        @user = User.create!(email: "tm-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
      end
      teardown { FileLayer.reset! }

      test "returns the ready thumbnail for a node's current content token" do
        serve info("node-1", token: "tok-1")
        p = @user.maker_previews.create!(node_id: "node-1", version_id: "tok-1", kind: "thumbnail",
                                         status: "ready", renderer_revision: revision_of("part.stl"))
        assert_equal p, ThumbnailMap.for(@user, [ "node-1" ]).thumb("node-1")
      end

      test "nil when there is no preview row for the current token" do
        serve info("node-2", name: "part.step", token: "tok")
        assert_nil ThumbnailMap.for(@user, [ "node-2" ]).thumb("node-2")
      end

      # A NODE WITH NO CONTENT TOKEN HAS NO CURRENT THUMBNAIL, EVEN THOUGH A `version_id: nil` ROW
      # CAN EXIST TO MATCH IT. `maker_previews.version_id` is NULLABLE and `Enqueue.call` really
      # does write one: `V1::Maker::PreviewsController#create` permits `version_id`, and
      # `refuse_stale_version!` returns false on a BLANK one and falls through, so a client that
      # sends none mints exactly this row.
      #
      # The port answers `content_token: nil` for a node with no content (a chunk node whose
      # version row is gone, a share/s3 node not yet hashed), which the page renders as "No
      # content yet." Matching that against the row's nil would present a stored artifact as the
      # thumbnail of a file the same page says has no content — `nil == nil` is a coincidence of
      # representation, not an answer about content. Hence the explicit token guard, which is the
      # single most fragile line in the resolution: the surrounding comparison is a plain equality
      # that reads as complete without it, and every other test here supplies a real token, so
      # deleting it goes green everywhere else.
      test "a node with no content token gets no thumbnail, even against a version_id-less row" do
        serve info("n-nul", name: "part.stl", token: nil)
        @user.maker_previews.create!(node_id: "n-nul", version_id: nil, kind: "thumbnail",
                                     status: "ready", renderer_revision: revision_of("part.stl"))
        assert_nil ThumbnailMap.for(@user, [ "n-nul" ]).thumb("n-nul"),
                   "a nil token must not match a nil version_id — that file has no current content"
      end

      test "degrades to empty (no raise) when the backend is unreachable" do
        FileLayer.current = FakeLayer.new(FileLayer::FetchError.new("nas down"))
        map = ThumbnailMap.for(@user, [ "node-3" ])
        assert_nil map.thumb("node-3")   # no thumbnail, but the call did not raise
      end

      test "empty input never touches the port" do
        FileLayer.current = FakeLayer.new(RuntimeError.new("should not be called"))
        assert_nil ThumbnailMap.for(@user, []).thumb("x")
      end

      # ------------------------------------------------------------------------------------
      # GAP 1: the enqueue seam. A node with no row rendered `thumb: nil` -> a spinner, and
      # nothing in the whole path — not the page, not `/files/thumbnails`, not MissingBackfill —
      # ever created the row. The cell span for 40 polls and then stopped, still spinning.
      # ------------------------------------------------------------------------------------

      test "enqueues a thumbnail for a renderable file that has no preview row" do
        serve info("n-new", name: "part.stl", token: "tok")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          ThumbnailMap.for(@user, [ "n-new" ])
        end
        row = @user.maker_previews.find_by(node_id: "n-new", kind: "thumbnail")
        assert_equal "tok", row.version_id
        assert_equal "pending", row.status
      end

      # `.sldprt`, AND THE FIXTURE HAS NOW MOVED TWICE — which is the point of the assertion below
      # rather than a reason to drop it. The first draft used `.step`, which renders (Mesh, via
      # F3D's OCCT plugin). It then used `.gcode` for a year, until 2026-08-26 wired every text
      # extension to TextThumb and g-code became renderable too — correctly, and this test went
      # red the same hour rather than quietly asserting nothing.
      #
      # A BINARY PROPRIETARY CAD SOURCE IS THE STABLE CHOICE: §9 records that SolidWorks and Fusion
      # have no FOSS parser, so `.sldprt` is unrenderable for a reason that does not expire the way
      # "we haven't got round to it" does. Registry::RENDERERS is longer than it looks, and the
      # `fixture assumption` line is what makes that survivable.
      test "does not enqueue a name no renderer handles" do
        serve info("n-cad", name: "part.sldprt", token: "tok")
        assert_nil Maker::Previews::Registry.for_filename("part.sldprt"), "fixture assumption"
        assert_no_enqueued_jobs { ThumbnailMap.for(@user, [ "n-cad" ]) }
        assert_nil @user.maker_previews.find_by(node_id: "n-cad")
      end

      # WHAT THE RENDERABLE-ONLY CHECK ACTUALLY BUYS, and the test above cannot see it: `Enqueue`
      # already refuses a name no renderer handles, so deleting the check from the loop creates no
      # rows and enqueues no jobs — it came back GREEN under exactly that mutation. The check earns
      # its place one line further down, where `budget -= 1` runs unconditionally: without it every
      # unrenderable file SPENDS A SLOT. A folder holding a wall of `.sldprt` ahead of its models
      # would then drain the whole budget onto files that can never have a thumbnail, and the
      # models behind them would spin on every visit forever — the backlog never draining is the
      # precise failure the budget was written to avoid.
      test "an unrenderable file does not spend a slot of the backfill budget" do
        assert_nil Maker::Previews::Registry.for_filename("x.sldprt"), "fixture assumption"
        unrenderable = Array.new(ThumbnailMap::BACKFILL_LIMIT) { |i| info("g#{i}", name: "g#{i}.sldprt", token: "t#{i}") }
        renderable   = Array.new(3) { |i| info("r#{i}", name: "r#{i}.stl", token: "s#{i}") }
        serve(*(unrenderable + renderable))

        assert_enqueued_jobs 3 do
          ThumbnailMap.for(@user, (unrenderable + renderable).map(&:node_id))
        end
      end

      # A directory whose name happens to carry a renderable extension is still a directory —
      # there are no bytes to render. `FilesController#backfill_thumbnails` asks `node.file?`;
      # here the same question is asked of the PORT's answer, which carries `kind` on all three
      # adapters.
      test "never enqueues a directory" do
        serve info("n-dir", name: "models.stl", kind: "dir", token: "tok")
        assert_no_enqueued_jobs { ThumbnailMap.for(@user, [ "n-dir" ]) }
        assert_nil @user.maker_previews.find_by(node_id: "n-dir")
      end

      test "does not enqueue when the backend is unreachable" do
        FileLayer.current = FakeLayer.new(FileLayer::FetchError.new("nas down"))
        assert_no_enqueued_jobs { ThumbnailMap.for(@user, [ "n-blip" ]) }
        assert_empty @user.maker_previews
      end

      # A node the port does not answer for (tombstoned mid-page, §14a's absent-key contract) has
      # no name, no kind and no token — there is nothing to enqueue and no row to invent.
      test "skips a node the port did not answer for" do
        serve info("n-live", token: "tok")
        assert_enqueued_jobs 1 do
          ThumbnailMap.for(@user, [ "n-live", "n-gone" ])
        end
        assert_nil @user.maker_previews.find_by(node_id: "n-gone")
      end

      # THE BUDGET. Same hazard as FilesController::BACKFILL_LIMIT: a library indexed before
      # previews shipped has files and no rows, and the page that lists them is not user-shaped.
      test "the backfill is bounded by BACKFILL_LIMIT" do
        ids = Array.new(ThumbnailMap::BACKFILL_LIMIT + 5) { |i| "n-#{i}" }
        serve(*ids.map { |id| info(id, name: "#{id}.stl", token: "tok-#{id}") })
        assert_enqueued_jobs ThumbnailMap::BACKFILL_LIMIT do
          ThumbnailMap.for(@user, ids)
        end
      end

      # ------------------------------------------------------------------------------------
      # THE CONTENT AXIS AT THIS DOOR, UNGUARDED HERE UNTIL 2026-08-19 — found by mutation, not by
      # reading. Deleting the CONTENT comparison from the resolution came back 2447 runs, 0
      # failures: every test above either supplies a matching token or supplies no row at all, so
      # nothing ever asked what happens to a row at a SUPERSEDED one. It was enforced the whole
      # time — first by the `version_id: live` IN-clause plus a `[node_id, version_id]` composite
      # key, now by one line in `Enqueue.current_preview?` — but never asserted, which is this
      # repo's dominant failure shape (§15) and the reason a redundancy is not a test.
      #
      # The stake is the file GRID: a file re-saved in place (the ordinary case on a mounted NAS —
      # LightBurn, a slicer) would keep painting the OLD picture as its current thumbnail, and the
      # backfill would count the node covered and never re-render it.
      # ------------------------------------------------------------------------------------

      test "does not serve a thumbnail rendered from superseded content" do
        serve info("n-old", name: "part.stl", token: "tok-new")
        @user.maker_previews.create!(node_id: "n-old", version_id: "tok-old", kind: "thumbnail",
                                     status: "ready", renderer_revision: revision_of("part.stl"))
        assert_nil ThumbnailMap.for(@user, [ "n-old" ]).thumb("n-old"),
                   "an artifact of DIFFERENT content must not be shown as this file's thumbnail"
      end

      test "re-enqueues a thumbnail rendered from superseded content" do
        serve info("n-old2", name: "part.stl", token: "tok-new")
        row = @user.maker_previews.create!(node_id: "n-old2", version_id: "tok-old",
                                           kind: "thumbnail", status: "ready",
                                           renderer_revision: revision_of("part.stl"))
        assert_enqueued_with(job: Maker::GeneratePreviewJob) { ThumbnailMap.for(@user, [ "n-old2" ]) }
        row.reload
        assert_equal "tok-new", row.version_id, "the row must be repointed at the current content"
        # UNLIKE a renderer bump (asserted below), a CONTENT move DOES blank the artifact — the
        # stored picture is of bytes that are gone, so the spinner is the honest replacement.
        assert_equal "pending", row.status
      end

      # ------------------------------------------------------------------------------------
      # GAP 2: the renderer-revision filter. §14h's recorded "172 of 174 LightBurn thumbnails sat
      # at revision 1 through two deploys" bug, one layer over from where it was fixed: a row from
      # an older build satisfied the has-a-row check, so nothing re-enqueued and the page served
      # an out-of-date picture as the file's thumbnail.
      # ------------------------------------------------------------------------------------

      test "does not serve a thumbnail built by an older renderer" do
        name = "sign.lbrn2"
        assert_operator revision_of(name), :>, Maker::Previews::Enqueue::BASE_REVISION,
                        "this test needs a renderer that has been bumped at least once"
        serve info("n-stale", name:, token: "tok")
        @user.maker_previews.create!(node_id: "n-stale", version_id: "tok", kind: "thumbnail",
                                     status: "ready", renderer_revision: revision_of(name) - 1)
        assert_nil ThumbnailMap.for(@user, [ "n-stale" ]).thumb("n-stale"),
                   "an older build's artifact must not be presented as this file's thumbnail"
      end

      test "re-enqueues a thumbnail built by an older renderer" do
        name = "sign.lbrn2"
        serve info("n-stale", name:, token: "tok")
        row = @user.maker_previews.create!(node_id: "n-stale", version_id: "tok", kind: "thumbnail",
                                           status: "ready",
                                           renderer_revision: revision_of(name) - 1)
        assert_enqueued_with(job: Maker::GeneratePreviewJob) { ThumbnailMap.for(@user, [ "n-stale" ]) }
        assert_equal revision_of(name), row.reload.renderer_revision
        # A RENDERER bump does NOT blank the artifact — the stored picture still depicts exactly
        # this file, only the code that built it moved on (Enqueue's own rule). Asserted here so a
        # future "reset it to pending for consistency" has something to go red.
        assert_equal "ready", row.status
      end

      # ------------------------------------------------------------------------------------
      # GAP 3: a row whose job was LOST. The backfill skipped every node whose row was current, so
      # a row wedged at `pending`/`processing` on current content never reached the
      # `Enqueue::STALLED_AFTER` heal that lives behind it. It asks `Enqueue.needs_job?` now, with
      # the read doors' policy: a stall is healed, a fresh render is believed, a failure stays put.
      # maker_page_thumbnails_test.rb drives the same thing through the Files page.
      # ------------------------------------------------------------------------------------

      test "re-enqueues a current row whose job was lost, and restamps it" do
        serve info("n-lost", name: "part.stl", token: "tok")
        row = travel_to(3.days.ago) do
          @user.maker_previews.create!(node_id: "n-lost", version_id: "tok", kind: "thumbnail",
                                       status: "processing", renderer_revision: revision_of("part.stl"))
        end

        assert_enqueued_with(job: Maker::GeneratePreviewJob) { ThumbnailMap.for(@user, [ "n-lost" ]) }
        assert_operator row.reload.updated_at, :>, 1.minute.ago, "the heal did not restamp the row"
        assert_no_enqueued_jobs { ThumbnailMap.for(@user, [ "n-lost" ]) }
      end

      # A FAILED RENDER IS NOT RETRIED FROM A PAGE RENDER — every Files, Models and Projects view
      # would otherwise queue a doomed render per failed file per view. MUTATION: give the backfill
      # `retry_failed: true` and this goes red.
      test "leaves a current failed row and a fresh in-flight row alone" do
        serve info("n-fail", name: "part.stl", token: "tok"), info("n-busy", name: "part.stl", token: "tok")
        @user.maker_previews.create!(node_id: "n-fail", version_id: "tok", kind: "thumbnail",
                                     status: "failed", renderer_revision: revision_of("part.stl"))
        @user.maker_previews.create!(node_id: "n-busy", version_id: "tok", kind: "thumbnail",
                                     status: "processing", renderer_revision: revision_of("part.stl"))

        assert_no_enqueued_jobs { ThumbnailMap.for(@user, [ "n-fail", "n-busy" ]) }
        assert_equal "failed", @user.maker_previews.find_by!(node_id: "n-fail").status
      end

      # ------------------------------------------------------------------------------------
      # The constraints the fix must not break.
      # ------------------------------------------------------------------------------------

      # ONE QUERY FOR THE PREVIEWS, HOWEVER MANY NODES. The revision filter runs in Ruby precisely
      # because the current revision depends on each node's filename, so there is no single value
      # to put in a WHERE — see Enqueue.current_preview?, which owns that comparison.
      # Constancy, never a literal (page_query_budget_test.rb's rule).
      test "resolves the previews in a constant number of queries" do
        counts = [ 3, 15 ].map do |n|
          ids = Array.new(n) { |i| "q#{n}-#{i}" }
          serve(*ids.map { |id| info(id, name: "#{id}.stl", token: "tok-#{id}") })
          ids.each do |id|
            @user.maker_previews.create!(node_id: id, version_id: "tok-#{id}", kind: "thumbnail",
                                         status: "ready", renderer_revision: revision_of("x.stl"))
          end
          count_queries { ThumbnailMap.for(@user, ids) }
        end
        assert_equal counts.first, counts.last,
                     "the preview lookup grows with the node count — it must stay one query"
      end

      # The poll endpoint reads this map every 2 seconds for up to 40 tries; enqueueing there
      # would be a per-node write on every tick for work the page render has already done.
      test "a caller holding the port's answer can opt out of the backfill" do
        i = info("n-poll", name: "part.stl", token: "tok")
        assert_no_enqueued_jobs do
          ThumbnailMap.from_info(@user, [ "n-poll" ], { "n-poll" => i }, backfill: false)
        end
        assert_nil @user.maker_previews.find_by(node_id: "n-poll")
      end

      # `from_info` is the same resolution over an answer the caller already holds — it must not
      # ask the port a second time. FilesController#index has @info_by_node in hand, and a second
      # stat_all there is a filesystem stat per node on share, doubled.
      test "from_info never touches the port" do
        FileLayer.current = FakeLayer.new(RuntimeError.new("should not be called"))
        i = info("n-held", name: "part.stl", token: "tok")
        map = ThumbnailMap.from_info(@user, [ "n-held" ], { "n-held" => i }, backfill: true)
        assert_nil map.thumb("n-held")
        assert @user.maker_previews.exists?(node_id: "n-held"), "the backfill still ran"
      end

      def count_queries
        n = 0
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
          unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
            n += 1
          end
        end
        yield
        n
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end
    end
  end
end
