require "test_helper"

module Maker
  # THE HISTORICAL RENDER CACHE, AND THE INVARIANT IT IS MOST LIKELY TO BREAK.
  #
  # §14b: "A `Maker::Preview` is ONE ROW PER (user, node, kind), REPOINTED as content moves — was
  # one per VERSION, which leaked a row + blob on every save." A thumbnail per version is exactly
  # what was removed, so the first test here is not a nicety: it is the guard that says this table
  # is the OTHER half of that sentence (the leak was eager generation, not old thumbnails) rather
  # than the bug coming back under a new name.
  class VersionPreviewTest < ActiveSupport::TestCase
    setup do
      # A REAL SHARE LIBRARY, NOT A STUBBED PORT. `FileLayer::Share#read` is what actually decides
      # "these bytes are gone" here — it REFUSES a content token that is not the node's current
      # content_hash rather than serving current bytes, because previews key on that token — so
      # driving the real adapter is what makes the `not_kept` test a probe rather than an argument
      # (§15). It also pins the adapter for all three CI legs, so the counts stay identical.
      @root = use_fresh_share_library!
      @user = User.create!(email: "vp-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
      @svg = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
    end

    # Put a file in the library and give it a catalog row. `content_hash` is what Share treats as
    # the node's CURRENT content token, so a VersionPreview naming this value can be read and one
    # naming any other value is honestly gone.
    def stage_file(name:, bytes:, content_hash:)
      path = @root.join(name)
      path.dirname.mkpath
      path.binwrite(bytes)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", deleted: false,
                          storage_path: name, content_hash:, size: bytes.bytesize)
    end

    def version_preview(node:, content_token:, name: nil, **attrs)
      Maker::VersionPreview.create!(project: @project, node_id: node.node_id, content_token:,
                                    source_filename: name || node.name, **attrs)
    end

    # ---------------------------------------------------------------- §14b isolation

    # THE TEST THIS WHOLE TASK EXISTS TO PASS. A historical render must be unable to create a
    # `Maker::Preview` row or to repoint the one that describes the file as it is TODAY —
    # `GeneratePreviewJob#commit_if_current` owns that row and knows nothing about this job.
    #
    # It runs the SUCCESSFUL path on purpose: `attach!` is where the write happens, so it is where
    # a "reuse the preview row, we already have the bytes" simplification would land.
    test "rendering a historical version does not create or repoint a Maker::Preview row" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "hist-token")

      # The CURRENT row, deliberately pointing at a DIFFERENT token — the ordinary state between a
      # content change and the scan's re-enqueue.
      current = @user.maker_previews.create!(node_id: node.node_id, kind: "thumbnail",
                                             version_id: "current-token", status: "ready")
      row = version_preview(node:, content_token: "hist-token")

      assert_no_difference "Maker::Preview.count" do
        Maker::RenderVersionPreviewJob.perform_now(version_preview_id: row.id)
      end

      assert_equal "current-token", current.reload.version_id,
        "a historical render must never repoint the current preview row"
      assert_equal "ready", current.status, "nor rewrite its status"
      # VACUITY CHECK (§15): without this, a job that silently did nothing at all would satisfy
      # every assertion above.
      assert_equal "ready", row.reload.state, "the historical render itself should have succeeded"
      assert row.asset.attached?, "a ready historical render must carry its image"
    end

    # ---------------------------------------------------------------- the unique key

    test "the model refuses a duplicate" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "t1")
      version_preview(node:, content_token: "t1")

      assert_raises(ActiveRecord::RecordInvalid) { version_preview(node:, content_token: "t1") }
    end

    # THE HALF THE VALIDATION CANNOT GIVE. `validates ... uniqueness` is a SELECT then an INSERT,
    # so two History opens can both read "no row yet" and both insert. Bypassing the validation is
    # how this test reaches the only mechanism that actually holds under concurrency.
    test "the unique index refuses a duplicate even when the validation is bypassed" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "t1")
      version_preview(node:, content_token: "t1")

      dup = Maker::VersionPreview.new(project: @project, node_id: node.node_id,
                                      content_token: "t1", source_filename: "bracket.svg")
      assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
    end

    # WHY `source_filename` IS IN THE KEY AT ALL, stated as a behaviour rather than a comment: one
    # content token can have two different pictures, because the NAME is what picks the renderer.
    # Drop it from the index and this pair collapses into one row that is wrong for one of them.
    test "the same content under a different name is a different cached render" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "t1")
      version_preview(node:, content_token: "t1", name: "bracket.svg")

      assert_difference "Maker::VersionPreview.count", 1 do
        version_preview(node:, content_token: "t1", name: "bracket.txt")
      end
    end

    # ---------------------------------------------------------------- retention

    # ALL FOUR QUADRANTS, because the fallback is only half the rule. `last_viewed_at` exists so a
    # version nobody looks at ages out even if it was rendered recently, AND so one people keep
    # opening stays even though it was rendered long ago — the second is the one a `created_at`
    # sweep would get wrong, and it is why `viewed recently, made long ago` is asserted to survive.
    test "stale_before reads last_viewed_at and falls back to created_at when it is nil" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "t1")

      # TIME IS SEPARATED BY MONTHS, NOT SECONDS (§15): a guard whose two events land in the same
      # second cannot fail, so each row is created at an explicit, far-apart time. The two
      # timestamps are captured ABSOLUTELY, before any travel — `1.day.ago` written INSIDE a
      # `travel_to(90.days.ago)` block means 91 days ago, which is the same side of the cutoff as
      # the value it was meant to contradict, so the quadrant it exists to prove would be a silent
      # duplicate of another one.
      recent = Time.current - 1.day
      long_ago = Time.current - 90.days

      viewed_long_ago = travel_to(recent) {
        version_preview(node:, content_token: "a", name: "a.svg", last_viewed_at: long_ago)
      }
      never_viewed_old = travel_to(long_ago) {
        version_preview(node:, content_token: "b", name: "b.svg", last_viewed_at: nil)
      }
      old_but_viewed = travel_to(long_ago) {
        version_preview(node:, content_token: "c", name: "c.svg", last_viewed_at: recent)
      }
      never_viewed_new = travel_to(recent) {
        version_preview(node:, content_token: "d", name: "d.svg", last_viewed_at: nil)
      }

      stale = Maker::VersionPreview.stale_before(30.days.ago).to_a

      assert_includes stale, viewed_long_ago, "a row nobody has opened in 90 days should age out"
      assert_includes stale, never_viewed_old,
        "a never-viewed row must fall back to created_at, not read as infinitely new"
      assert_not_includes stale, old_but_viewed,
        "a row people keep opening must survive however long ago it was rendered"
      assert_not_includes stale, never_viewed_new,
        "a never-viewed row must not read as infinitely old the moment History mints it"
    end

    # ---------------------------------------------------------------- the three terminals

    # THE ORDINARY CASE ON `share`, NOT AN ERROR. The maker's overwrite in Finder destroyed the
    # previous bytes before this app ever saw them (§14a — share and s3 are current-state only), so
    # a history tile that says "not kept" is telling the truth about their storage. Reporting it as
    # `failed` would tell them their history is broken when it is not.
    test "bytes the store no longer has produce not_kept, not failed" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "current-token")
      row = version_preview(node:, content_token: "a-version-share-did-not-keep")

      Maker::RenderVersionPreviewJob.perform_now(version_preview_id: row.id)

      assert_equal "not_kept", row.reload.state
      assert_nil row.error, "not_kept is not an error condition and must not populate `error`"
      assert_not row.asset.attached?
    end

    # A THIRD FACT, DISTINCT FROM BOTH OTHERS: nothing was lost and nothing went wrong; this box
    # simply has no permissive renderer for the format.
    test "a format with no renderer is unsupported, not not_kept and not failed" do
      node = stage_file(name: "part.sldprt", bytes: "binary", content_hash: "t1")
      row = version_preview(node:, content_token: "t1")

      Maker::RenderVersionPreviewJob.perform_now(version_preview_id: row.id)

      assert_equal "unsupported", row.reload.state
      assert_match(/sldprt/, row.error)
    end

    # AN UNMOUNTED SHARE MUST NEVER READ AS "your history was not kept" (§14a). Share answers the
    # RETRYABLE `FetchError` when the library root looks unmounted and the TERMINAL `NotFound` when
    # the library is there and one file is not; only the second is a real loss. Conflating them is
    # the one mistake this job can make that lies to a maker about their own history.
    test "an unmounted library leaves the row pending rather than marking it not_kept" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "t1")
      row = version_preview(node:, content_token: "t1")
      FileUtils.remove_entry(@root) # the NAS went away mid-browse

      Maker::RenderVersionPreviewJob.perform_now(version_preview_id: row.id)

      assert_equal "pending", row.reload.state,
        "a transient fetch failure must stay non-terminal so the retry can still succeed"
      assert_match(/retrying/, row.error)
    end

    # ---------------------------------------------------------------- housekeeping

    test "tenancy comes from the project, so the pointer is required" do
      assert_not Maker::VersionPreview.new(node_id: "n", content_token: "t",
                                           source_filename: "a.svg").valid?
    end

    test "user delegates through the project" do
      node = stage_file(name: "bracket.svg", bytes: @svg, content_hash: "t1")
      assert_equal @user, version_preview(node:, content_token: "t1").user
    end
  end
end
