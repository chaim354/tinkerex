require "test_helper"
require "support/gerber_fixture"

module Maker
  # WHAT THE SERVER LEARNS FROM A ZIP WITHOUT EXTRACTING IT — the listing the zip's own file page
  # reads. Tested as a unit for `GerberSetsTest`'s reason: it is a pure function of the archive's
  # bytes plus one port read, and driving a web page to ask it would be slower and no more true.
  # The markup is test/integration/web/gerber_preview_test.rb's subject and the browser half —
  # JSZip really extracting these members — is test/system/gerber_test.rb's.
  #
  # SHARE IS PINNED BEFORE ANY NODE IS CREATED, exactly as in GerberSetsTest: `for` really opens the
  # archive through the port, so a fixture with no bytes behind it would answer nil on every leg and
  # every assertion here would pass for the wrong reason.
  #
  # THE CACHE IS THE NULL STORE IN TEST (config/environments/test.rb), so every `for` below really
  # reads. The one test that is ABOUT the cache swaps a MemoryStore in and restores it.
  class GerberArchiveTest < ActiveSupport::TestCase
    include GerberFixture

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "gerber-archive-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    teardown { FileLayer.reset! }

    # Every port read this block performs, by node_id — the singleton-method technique
    # gerber_sets_test.rb uses, because this suite has no Object#stub (Minitest 6). `raising:` makes
    # each of those reads fail with the port's own error instead, which is how a test stands in for
    # an unmounted share or a missing file without touching the bytes.
    def counting_reads(raising: nil)
      adapter = FileLayer.current
      original = adapter.method(:read)
      reads = []
      adapter.define_singleton_method(:read) do |user, **kw|
        reads << kw[:node_id]
        raise raising, "the store did not answer" if raising

        original.call(user, **kw)
      end
      begin
        yield reads
      ensure
        adapter.singleton_class.remove_method(:read)
      end
    end

    # --- what is in the archive --------------------------------------------------

    # THE REPORT'S OWN SHAPE: Fusion 360 CAM outputs, layers three directories deep, a drill file in
    # a sibling directory, PnP text that is not a layer, and a job naming the four.
    test "a Fusion export lists its layer PATHS, name-ordered, and names its job" do
      node = write_gerber_zip!

      listing = GerberArchive.for(user: @user, node:)

      assert_equal fusion_zip_members, listing.members
      assert_equal listing.members, listing.stacked
      assert_equal "gerber_job.gbrjob", listing.job_name
    end

    # THE `.txt` IS NOT A LAYER and neither is the job: `members` is the pcb-role set only, which is
    # what stops tracespace being handed assembly notes as a copper layer.
    test "members hold no assembly text and no job file" do
      node = write_gerber_zip!

      listing = GerberArchive.for(user: @user, node:)

      assert_empty listing.members.grep(/\.txt\z/)
      assert_empty listing.members.grep(/\.gbrjob\z/), "the manifest is not one of its own layers"
      assert_empty listing.stacked.grep(/\.gbrjob\z/)
    end

    # --- the job member ----------------------------------------------------------

    # THE LIST AND THE STACK ARE DIFFERENT LISTS INSIDE A ZIP TOO — GerberSets's folder rule, applied
    # to members. A layer the manifest does not name is still LISTED so nothing goes invisible.
    test "a job naming a subset stacks the subset and still lists everything" do
      body = gerber_zip("gerbers/board.gtl" => MINIMAL_GERBER,
                        "gerbers/old-revision.gtl" => MINIMAL_GERBER,
                        "gerbers/board.gbrjob" => gerber_job("board.gtl"))
      node = write_gerber_zip!(body:)

      listing = GerberArchive.for(user: @user, node:)

      assert_equal %w[gerbers/board.gtl gerbers/old-revision.gtl], listing.members
      assert_equal %w[gerbers/board.gtl], listing.stacked
    end

    # `Path` IS MATCHED BY BASENAME, NEVER RESOLVED AS A PATH — GerberSets's rule, and inside an
    # archive it matters more: the members really do sit under directories, and the manifest names
    # them bare.
    test "a job's Path is matched by basename against the member paths" do
      body = gerber_zip("CAMOutputs/GerberFiles/board.gtl" => MINIMAL_GERBER,
                        "CAMOutputs/GerberFiles/board.gbl" => MINIMAL_GERBER,
                        "CAMOutputs/GerberFiles/board.gbrjob" => gerber_job("board.gtl"))
      node = write_gerber_zip!(body:)

      assert_equal %w[CAMOutputs/GerberFiles/board.gtl],
                   GerberArchive.for(user: @user, node:).stacked
    end

    # EVERY FAILURE MODE FALLS BACK TO EVERY LAYER IN THE ARCHIVE, which is the honest answer when
    # the manifest has told us nothing usable — GerberSets's directory branch, one level in.
    test "a job that is unusable falls back to stacking every layer" do
      {
        "not json at all" => "{{{",
        "json that is not an object" => "[1, 2, 3]",
        "an object with no FilesAttributes" => JSON.generate("Header" => {}),
        "naming nothing this archive holds" => gerber_job("somewhere-else.gtl")
      }.each do |why, job_body|
        body = gerber_zip("gerbers/board.gtl" => MINIMAL_GERBER,
                          "gerbers/board.gbl" => MINIMAL_GERBER,
                          "gerbers/board.gbrjob" => job_body)
        node = write_gerber_zip!(name: "board-#{SecureRandom.hex(3)}.zip", body:)

        assert_equal %w[gerbers/board.gbl gerbers/board.gtl],
                     GerberArchive.for(user: @user, node:).stacked, why
      end
    end

    # AN EXPORT WITH NO MANIFEST IS THE ORDINARY HAND-ROLLED CASE and stacks everything.
    test "an archive with no job member stacks every layer and names no job" do
      node = write_gerber_zip!(body: fusion_zip(job: false))

      listing = GerberArchive.for(user: @user, node:)

      assert_equal fusion_zip_members, listing.stacked
      assert_nil listing.job_name
    end

    # --- not a board -------------------------------------------------------------

    test "a zip holding no Gerber member at all is not a board" do
      node = write_gerber_zip!(body: gerber_zip("notes.txt" => "hello", "src/main.c" => "int main(){}"))

      assert_nil GerberArchive.for(user: @user, node:)
    end

    # A MANIFEST ALONE IS NOT A BOARD: there is nothing to stack, and tracespace would be handed
    # JSON or nothing at all.
    test "a zip holding only a job file is not a board" do
      node = write_gerber_zip!(body: gerber_zip("gerber_job.gbrjob" => gerber_job("board.gtl")))

      assert_nil GerberArchive.for(user: @user, node:)
    end

    test "a file that is not a zip at all is not a board" do
      node = write_gerber!(name: "board.gtl")

      assert_nil GerberArchive.for(user: @user, node:)
    end

    # GARBAGE NAMED `.zip` IS nil, NOT A 500 — rubyzip raises Zip::Error and this class answers the
    # way it answers every other failure.
    test "garbage bytes named .zip are not a board" do
      node = write_gerber_zip!(body: "this is not an archive")

      assert_nil GerberArchive.for(user: @user, node:)
    end

    # A ZERO-BYTE `.zip` IS THE ONE INPUT rubyzip DOES NOT REPORT AS A Zip::Error — probed on 3.6.0,
    # `open_buffer` raises `TypeError: no implicit conversion of StringIO into String` — so
    # `listing_from` guards on empty bytes rather than rescuing a class broad enough to hide a bug.
    # An interrupted export really does leave one of these on a share.
    # A ZIP CUT SHORT IS THE ORDINARY MALFORMED SHAPE — an interrupted copy onto the NAS — and rubyzip
    # 3.6.0 does not answer it with Zip::Error: an archive minus its last 1, 5 or 10 bytes raises
    # NoMethodError or ArgumentError out of `open_buffer` (measured in the 3MF review, which found
    # this reader raising identically on the same bytes), so every view of such a file was a 500. The
    # archive is now opened behind a rescue of exactly those classes and nothing else (`open_zip`).
    # MUTATION: narrowing that rescue back to `Zip::Error` reds this on the 1- and 5-byte cuts.
    test "a zip cut short by a few bytes is not a board, and does not raise" do
      whole = fusion_zip
      [ 1, 5, 10 ].each do |cut|
        assert_nil GerberArchive.listing_from(whole[0...-cut]), "cut by #{cut} bytes"
      end
    end

    test "a zero-byte .zip is not a board, and does not raise" do
      node = write_gerber_zip!(body: "")

      assert_nil GerberArchive.for(user: @user, node:)
      assert_nil GerberArchive.listing_from("")
    end

    # AN UNMOUNTED SHARE MUST NOT 500 A PROJECT PAGE. The port's own two conditions are rescued for
    # `GerberSets.job_layer_names`'s reason; driven here by deleting the bytes under a live row.
    test "a zip whose bytes are gone is not a board rather than raising" do
      node = write_gerber_zip!
      @root.join(node.storage_path).delete

      assert_nil GerberArchive.for(user: @user, node:)
    end

    # --- the two bounds ----------------------------------------------------------

    # THE SIZE CHECK IS ON THE CATALOG'S OWN COLUMN, so an oversized zip costs NO READ — the same
    # argument GerberSets::READ_LIMIT makes for a job file. Asserted through the row rather than by
    # writing 16 MB.
    test "a zip past READ_LIMIT is not a board and is never read" do
      node = write_gerber_zip!
      node.update_column(:size, GerberArchive::READ_LIMIT + 1)

      counting_reads do |reads|
        assert_nil GerberArchive.for(user: @user, node:)
        assert_empty reads, "an oversized archive was opened through the port"
      end
    end

    # A NULL SIZE IS REFUSED, NOT READ. `nil.to_i` is 0, which would pass the cap and hand the
    # read to the port's own 256 MB bound — sixteen times this class's. Nothing writes a NULL size
    # today; this pins what the guard means if one ever appears (the review's finding).
    test "a zip whose size is unknown is not a board and is never read" do
      node = write_gerber_zip!
      node.update_column(:size, nil)

      counting_reads do |reads|
        assert_nil GerberArchive.for(user: @user, node:)
        assert_empty reads, "an archive of unknown size was opened through the port"
      end
    end

    # THE JOB MEMBER HAS ITS OWN CAP, judged on the entry's uncompressed size before it is read.
    # Past it the manifest is ignored and every layer stacks, exactly as an unparseable one does.
    test "a job member past the job cap is ignored and every layer stacks" do
      fat = JSON.generate("FilesAttributes" => [ { "Path" => "board.gtl" } ],
                          "Padding" => "x" * (GerberSets::READ_LIMIT + 1))
      body = gerber_zip("board.gtl" => MINIMAL_GERBER, "board.gbl" => MINIMAL_GERBER,
                        "board.gbrjob" => fat)
      node = write_gerber_zip!(body:)

      assert_equal %w[board.gbl board.gtl], GerberArchive.for(user: @user, node:).stacked
    end

    # THE COST IS CONSTANT IN THE ARCHIVE'S SIZE — the property a project page's budget depends on
    # (`test/integration/web/page_query_budget_test.rb` asserts constancy in N, but its fixtures hold
    # no archives, so this claim is pinned HERE, where the code is, rather than left to a page test
    # that could never see it).
    #
    # ASSERTED AS EQUAL COUNTS, NEVER A LITERAL, and MEASURED rather than reasoned: the listing
    # itself issues nothing (the node is already in hand and the bytes come through the port), but
    # `FileLayer::Share#read` resolves the node_id to a storage_path first, so a read really does
    # cost ONE query — the same per-file shape a `.gbrjob` read already has, and it is per ARCHIVE,
    # not per member. The count differs per backend, which is the other reason not to pin a number.
    test "listing an archive costs the same whether it holds four members or forty" do
      small = write_gerber_zip!(name: "small.zip")
      big = write_gerber_zip!(name: "big.zip", body: gerber_zip(
        (1..40).to_h { |i| [ "CAMOutputs/GerberFiles/layer#{i.to_s.rjust(2, '0')}.gbr", MINIMAL_GERBER ] }
      ))

      assert_equal 40, GerberArchive.for(user: @user, node: big).members.size
      assert_equal queries_while { GerberArchive.for(user: @user, node: small) },
                   queries_while { GerberArchive.for(user: @user, node: big) },
                   "listing an archive grows with the number of members it holds"
    end

    # --- the cache ---------------------------------------------------------------

    # ONE READ PER (node, content token). A maker reloads the zip's page; re-opening a 10 MB
    # archive each time is exactly the cost this cache exists to avoid — and nil is cached too, so
    # a zip of firmware stays known-not-a-board.
    #
    # MUTATION: drop the token from the cache key and the last assertion fails — the re-exported
    # archive would answer from the stale entry.
    test "a listing is read once per content token, nil included" do
      node = write_gerber_zip!
      not_a_board = write_gerber_zip!(name: "firmware.zip", body: gerber_zip("notes.txt" => "hi"))

      with_memory_cache do
        counting_reads do |reads|
          assert_equal fusion_zip_members, GerberArchive.for(user: @user, node:).members
          assert_equal fusion_zip_members, GerberArchive.for(user: @user, node:).members
          assert_equal [ node.node_id ], reads, "the second call re-opened the archive"

          assert_nil GerberArchive.for(user: @user, node: not_a_board)
          assert_nil GerberArchive.for(user: @user, node: not_a_board)
          assert_equal [ node.node_id, not_a_board.node_id ], reads,
                       "a nil listing was not cached, so a zip of firmware is re-read on every view"
        end

        # A RE-EXPORT IS NEW CONTENT AND READS AGAIN. The bytes on the share change with it, so this
        # also proves the cache is answering about the CURRENT content rather than the first one.
        @root.join(node.storage_path).binwrite(fusion_zip(stem: "rev-b"))
        node.update_column(:content_hash, Digest::SHA256.hexdigest(fusion_zip(stem: "rev-b")))
        counting_reads do |reads|
          assert_equal fusion_zip_members(stem: "rev-b"),
                       GerberArchive.for(user: @user, node: node.reload).members
          assert_equal [ node.node_id ], reads, "a new content token did not re-read the archive"
        end
      end
    end

    # A STORE THAT DID NOT ANSWER IS THIS VIEW'S nil, NEVER THE CONTENT'S. activesupport writes a nil
    # block result unless `skip_nil`, so the rescue that sat INSIDE the fetch cached "the store did
    # not answer" as "not a board" for CACHE_TTL — Solid Cache in production, surviving deploys —
    # under a key that does not move when the store comes back: the zip lost its board on both file
    # pages, and ProjectIntake filed it into the source folder on the next sweep. The null store this
    # suite runs on cannot see any of that, so both tests stand a MemoryStore up.
    #
    # MUTATION: move the rescue back inside `Rails.cache.fetch` and the view after the outage answers
    # the cached nil without reading; delete the banner line and the first test's flag goes red.
    test "an unreachable store is nil for that view, raises the banner, and is never cached" do
      node = write_gerber_zip!
      seen = outage_then_recovery(node, FileLayer::FetchError)

      assert_nil seen[:during]
      assert seen[:banner], "an outage degraded the board to nil without raising the banner"
      assert_equal fusion_zip_members, seen[:after]&.members,
                   "the outage's nil was cached, so the zip stayed not-a-board after the store came back"
      assert_equal [ node.node_id, node.node_id ], seen[:reads], "the view after the outage did not read again"
    end

    # NotFound IS NOT A FACT ABOUT THE CONTENT EITHER: Share#read answers it for a path that is not
    # there right now, which includes an outside move until the next scan pairs it — and pairing
    # keeps node_id AND content_hash, so a cached nil would outlive the repair. No banner: a file that
    # is gone is not an outage (app/models/current.rb).
    test "a missing file is nil without the banner, and that nil is never cached either" do
      node = write_gerber_zip!
      seen = outage_then_recovery(node, FileLayer::NotFound)

      assert_nil seen[:during]
      assert_nil seen[:banner], "a missing file raised the banner; nothing is down"
      assert_equal fusion_zip_members, seen[:after]&.members,
                   "a missing file's nil was cached, so the zip stayed not-a-board once it was back"
      assert_equal [ node.node_id, node.node_id ], seen[:reads], "the view after the miss did not read again"
    end

    # THE NAMESPACE MOVED WITH THE FIX, because production's Solid Cache already holds nils that
    # outages wrote under the old one and would serve them for up to 30 more days. MUTATION: put
    # the old namespace back and this answers the planted nil.
    test "an answer cached under the namespace outages poisoned is never read" do
      node = write_gerber_zip!

      with_memory_cache do
        Rails.cache.write([ "gerber-archive", node.node_id, node.content_hash ], nil)
        assert_equal fusion_zip_members, GerberArchive.for(user: @user, node:)&.members,
                     "a nil cached under the pre-fix namespace was served"
      end
    end

    private

    # ONE VIEW WHILE EVERY PORT READ RAISES `error`, THEN ONE AFTER THE STORE IS BACK, against a fresh
    # MemoryStore — so the second answer is exactly what the first one left in the cache. Returns what
    # each view answered, whether the first raised the banner, and every port read the two made.
    def outage_then_recovery(node, error)
      with_memory_cache do
        Current.reset
        during, failed_reads = counting_reads(raising: error) { |r| [ GerberArchive.for(user: @user, node:), r ] }
        banner = Current.library_unreachable
        Current.reset
        after, reads = counting_reads { |r| [ GerberArchive.for(user: @user, node:), r ] }
        { during:, banner:, after:, reads: failed_reads + reads }
      end
    end

    # `sql.active_record` while the block runs, SCHEMA/TRANSACTION/PRAGMA excluded exactly as
    # page_query_budget_test.rb excludes them: they are this call's cost only by accident of order.
    def queries_while
      queries = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        queries += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) ||
                            payload[:sql].start_with?("PRAGMA")
      end
      yield
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # The null store answers nothing, so a cache test needs a real one. Restored in `ensure`: a
    # leaked MemoryStore would make every later test in this worker cache-hit on stale rows.
    def with_memory_cache
      prior = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = prior
    end
  end
end
