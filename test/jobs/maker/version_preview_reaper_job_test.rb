require "test_helper"

module Maker
  # RETENTION FOR THE HISTORICAL RENDER CACHE. `Maker::VersionPreview`'s header called this out as
  # missing in as many words — "SAY WHAT IS NOT HERE: NOTHING SWEEPS YET" — and its `stale_before`
  # scope has existed as the retention KEY with nothing behind it. These tests are the sweeper.
  #
  # WHAT MAKES THIS SAFE WHERE `Maker::AttachmentReaper` NEEDS A 30-DAY GRACE: the row is a cache
  # and destroying it loses nothing. So these tests are not about revivability at all — they are
  # about the two windows and the fallback, which is the whole of the mechanism.
  #
  # EVERY EVENT IS SEPARATED BY DAYS, NEVER BY SECONDS (§15). The row under test is written in the
  # same second as the sweep that is supposed to spare or reap it, so a fixture built at
  # `Time.current` and asserted against a window makes a guard that cannot fail; `travel_to` moves
  # `created_at` itself, which is the column the fallback actually reads.
  class VersionPreviewReaperJobTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "vpr-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
      @token = 0
    end

    # Mint one cached render AS OF `created`, which is what the fallback reads. `attached:` is on by
    # default because a terminal row normally carries the blob this sweep exists to reclaim.
    def render_row(created:, last_viewed_at: nil, state: "ready", attached: true)
      @token += 1
      row = travel_to(created) do
        Maker::VersionPreview.create!(project: @project, node_id: "n1", content_token: "c#{@token}",
                                      source_filename: "bracket.svg", state:, last_viewed_at:)
      end
      if attached
        row.asset.attach(io: StringIO.new("PNGBYTES"), filename: "v.png", content_type: "image/png")
      end
      row
    end

    def reap!(**opts) = Maker::VersionPreviewReaperJob.perform_now(**opts)

    # ------------------------------------------------------------------ the terminal window

    test "a terminal row past the retention window is destroyed" do
      row = render_row(created: 200.days.ago)

      assert_equal 1, reap!
      assert_not Maker::VersionPreview.exists?(row.id)
    end

    # Deleting the row without the blob would trade a database leak for a stored-file one on the
    # very Kamal volume (tinkerex#160) this sweep exists to bound.
    test "the blob goes with the row, not just the row" do
      row = render_row(created: 200.days.ago)
      blob_id = row.asset.blob.id

      reap!
      assert_not ActiveStorage::Blob.exists?(blob_id), "the row was destroyed but its blob was left"
      assert_not ActiveStorage::Attachment.exists?(record_id: row.id, record_type: "Maker::VersionPreview")
    end

    test "a terminal row inside the retention window survives" do
      row = render_row(created: 10.days.ago)

      assert_equal 0, reap!
      assert Maker::VersionPreview.exists?(row.id)
    end

    # THE POINT OF `last_viewed_at` BEING THE KEY RATHER THAN `created_at`: a render made two
    # hundred days ago that someone opened last week is a live cache entry.
    test "a row viewed recently survives however long ago it was rendered" do
      row = render_row(created: 200.days.ago, last_viewed_at: 3.days.ago)

      assert_equal 0, reap!
      assert Maker::VersionPreview.exists?(row.id)
    end

    # THE FALLBACK, AND IT IS THE MAINLINE RATHER THAN AN EDGE CASE: nothing writes `last_viewed_at`
    # today, so every live row ages from `created_at`. A null must read as neither infinitely old
    # (which would evict every row the moment History minted it) nor infinitely new (which would
    # make an unviewed row immortal) — both directions are asserted here.
    test "a never-viewed row falls back to created_at in both directions" do
      old = render_row(created: 200.days.ago, last_viewed_at: nil)
      fresh = render_row(created: 2.days.ago, last_viewed_at: nil)

      assert_equal 1, reap!
      assert_not Maker::VersionPreview.exists?(old.id),
                 "a never-viewed row must fall back to created_at, not read as infinitely new"
      assert Maker::VersionPreview.exists?(fresh.id),
             "a never-viewed row must not read as infinitely old the moment History mints it"
    end

    # ------------------------------------------------------------------ the pending window

    # A `pending` row that never resolved is never re-enqueued — `HistoryController#mint_missing`
    # gates its enqueue on `previously_new_record?` — so the tile spins forever and destroying the
    # row is the only repair. It gets the SHORT window, and this is the test that proves the split
    # is a split rather than one window written twice.
    test "a pending row older than a day is reaped even though the terminal window has not passed" do
      stuck = render_row(created: 5.days.ago, state: "pending", attached: false)

      assert_equal 1, reap!
      assert_not Maker::VersionPreview.exists?(stuck.id)
    end

    test "a pending row younger than a day is left for its render to finish" do
      fresh = render_row(created: 2.hours.ago, state: "pending", attached: false)

      assert_equal 0, reap!
      assert Maker::VersionPreview.exists?(fresh.id)
    end

    # The converse of the split: a TERMINAL row five days old must not be swept by the pending
    # window. Collapsing the two arms in that direction throws away a warm cache every night.
    test "a terminal row older than the pending window is not swept by it" do
      row = render_row(created: 5.days.ago, state: "not_kept", attached: false)

      assert_equal 0, reap!
      assert Maker::VersionPreview.exists?(row.id)
    end

    # `failed` is TERMINAL and deliberately keeps the long window: it is the state
    # Maker::VersionPreview's header says "should be read as a bug", and reaping it on the pending
    # window would clear the evidence an operator greps `error` for before anyone saw it.
    test "a failed row keeps the terminal window rather than the pending one" do
      row = render_row(created: 5.days.ago, state: "failed", attached: false)

      assert_equal 0, reap!
      assert Maker::VersionPreview.exists?(row.id)
    end

    # ------------------------------------------------------------------ operator surface

    test "dry_run reports what it would reap and deletes nothing" do
      row = render_row(created: 200.days.ago)
      stuck = render_row(created: 5.days.ago, state: "pending", attached: false)

      assert_equal 2, reap!(dry_run: true)
      assert Maker::VersionPreview.exists?(row.id)
      assert Maker::VersionPreview.exists?(stuck.id)
      assert_equal 2, reap!
    end

    test "the windows are overridable so an operator can sweep harder without a deploy" do
      row = render_row(created: 10.days.ago)

      assert_equal 0, reap!
      assert_equal 1, reap!(retention: 5.days)
    end
  end
end
