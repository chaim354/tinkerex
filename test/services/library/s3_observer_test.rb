require "test_helper"
require_relative "../../support/fake_s3"

module Library
  # Observes a bucket the way Scanner observes a directory: it OBSERVES, the Reconciler DECIDES.
  # Same Reconciler, same guard, same pairing -- which is the point, because that is where every
  # one of Phase 2a's bugs lived. The listing is the only thing that differs, and it is where this
  # backend's landmines are.
  class S3ObserverTest < ActiveSupport::TestCase
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "obs-#{SecureRandom.hex(4)}@example.com")
    end

    def adapter(client: nil)
      FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                        secret_access_key: "sk", prefix: PREFIX, client: client || @fake.client)
    end

    def scan!(**kw) = Library::S3Observer.call(@user, adapter: adapter, **kw)

    def files = @user.nodes.present.where(kind: "file")

    # ---------------------------------------------------------------- the basics

    test "indexes an object with size, identity, and NANOSECOND mtime" do
      @fake.seed!("#{PREFIX}/a.stl", "hello", last_modified: Time.at(1_700_000_000))
      scan!

      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal "a.stl", node.name
      assert_equal "file", node.kind
      assert_equal 5, node.size
      assert_equal "md5:#{Digest::MD5.hexdigest('hello')}", node.content_hash
      # S3's last_modified is SECOND-granularity, but the column and FileInfo's contract are NANOS
      # end-to-end. Passing seconds through is the bug that shipped twice for real in the mount
      # adapters.
      assert_equal 1_700_000_000_000_000_000, node.mtime
    end

    test "the identity never carries the quotes S3 wraps every ETag in" do
      @fake.seed!("#{PREFIX}/q.stl", "quoted")
      scan!
      assert_not_includes @user.nodes.find_by!(storage_path: "q.stl").content_hash, '"'
    end

    test "excludes the trash prefix" do
      @fake.seed!("#{PREFIX}/.trash/n1/old.stl", "deleted")
      @fake.seed!("#{PREFIX}/live.stl", "x")
      scan!

      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
      assert @user.nodes.find_by(storage_path: "live.stl")
    end

    test "an object outside the prefix is not in this library" do
      @fake.seed!("somewhere-else/other.stl", "not ours")
      @fake.seed!("#{PREFIX}/ours.stl", "ours")
      scan!

      assert_equal 1, files.count
      assert @user.nodes.find_by(storage_path: "ours.stl")
    end

    # A sibling keyspace, not a subdirectory: prefix "library" must not swallow "libraryX/". This
    # is what the trailing slash on FileLayer::S3#listing_prefix buys, and it is asserted here
    # because the observer is the only caller that lists the whole library.
    test "a sibling prefix sharing our prefix's leading characters is not in this library" do
      @fake.seed!("#{PREFIX}-other/nope.stl", "theirs")
      @fake.seed!("#{PREFIX}/yes.stl", "ours")
      scan!

      assert_equal 1, files.count
      assert @user.nodes.find_by(storage_path: "yes.stl")
    end

    # ---------------------------------------------------------------- LANDMINE 6: no directories

    # S3 has no directories -- the tree is synthesized from key prefixes, or parent_node_id
    # resolves to nothing and browse/search/tags stop working below the top level.
    test "synthesizes directory nodes from key prefixes so the tree still has parents" do
      @fake.seed!("#{PREFIX}/cad/brackets/b.stl", "x")
      scan!

      file     = @user.nodes.find_by!(storage_path: "cad/brackets/b.stl")
      brackets = @user.nodes.find_by!(storage_path: "cad/brackets")
      cad      = @user.nodes.find_by!(storage_path: "cad")

      assert_equal "dir", cad.kind
      assert_equal "dir", brackets.kind
      assert_equal brackets.node_id, file.parent_node_id
      assert_equal cad.node_id, brackets.parent_node_id
      assert_nil cad.parent_node_id
    end

    # nil, not 0 and not the newest child's mtime: S3 has no directory mtime, so there is nothing
    # to report. Pins that the nullable column and Reconciler#ensure_dirs really do tolerate it --
    # confirmed rather than assumed, per the plan's instruction.
    test "a synthesized directory carries no mtime and no size" do
      @fake.seed!("#{PREFIX}/cad/b.stl", "x")
      scan!

      cad = @user.nodes.find_by!(storage_path: "cad")
      assert_nil cad.mtime
      assert_nil cad.size
    end

    # The S3 console (and most tools) make a "folder" as a ZERO-BYTE object with a TRAILING SLASH.
    # Index it as a file and File.basename("cad/") gives "cad" -- a phantom file node named `cad`
    # at storage_path "cad/", living beside the real dir node `cad`. Distinct strings, so the
    # partial unique index permits BOTH, and the phantom is in every browse view forever.
    test "a zero-byte directory-marker object is a directory, not a phantom file" do
      @fake.seed!("#{PREFIX}/cad/", "")
      @fake.seed!("#{PREFIX}/cad/real.stl", "x")
      scan!

      assert_equal 1, files.count, "the only file is real.stl -- the marker is not a file"
      assert_nil @user.nodes.find_by(storage_path: "cad/"), "no node may carry a trailing slash"
      assert_equal "dir", @user.nodes.find_by!(storage_path: "cad").kind
    end

    # The test above cannot tell "the marker became a directory" from "the marker was dropped on
    # the floor" -- `cad/real.stl` synthesizes `cad` either way. This one can: the marker is the
    # ONLY evidence the folder exists. An empty folder made in the console should appear as one.
    test "a directory-marker object with no children is still a directory" do
      @fake.seed!("#{PREFIX}/empty-folder/", "")
      scan!

      node = @user.nodes.find_by!(storage_path: "empty-folder")
      assert_equal "dir", node.kind
      assert_equal 0, files.count
    end

    # The library root's own marker object addresses nothing inside the library.
    test "a marker object for the prefix itself is not a node" do
      @fake.seed!("#{PREFIX}/", "")
      @fake.seed!("#{PREFIX}/real.stl", "x")
      scan!

      assert_equal 1, @user.nodes.present.count, "only real.stl -- the root marker is not an entry"
      assert @user.nodes.find_by(storage_path: "real.stl")
    end

    # LANDMINE 6's phantom arriving by a SECOND route. S3's keyspace is flat, so "cad//x.stl" is a
    # perfectly legal key and is not a path: File.dirname gives "cad/", whose ancestor chain mints
    # a dir node at storage_path "cad/" beside the real `cad` -- the identical phantom the
    # trailing-slash rule prevents, wearing different punctuation.
    test "a key with an empty path segment is skipped, not turned into a phantom directory" do
      @fake.seed!("#{PREFIX}/cad//x.stl", "x")
      @fake.seed!("#{PREFIX}/cad/ok.stl", "y")
      scan!

      assert_equal 1, files.count
      assert @user.nodes.find_by(storage_path: "cad/ok.stl")
      assert_nil @user.nodes.find_by(storage_path: "cad/"), "no node may carry a trailing slash"
      assert_nil @user.nodes.find_by(storage_path: "cad//x.stl")
    end

    # A ".." segment would mint a node FileLayer::S3#key_for_rel then refuses to read as a prefix
    # escape -- a file in the library that can never be opened.
    test "a key with a .. segment is skipped rather than indexed as an unreadable node" do
      @fake.seed!("#{PREFIX}/cad/../escape.stl", "x")
      @fake.seed!("#{PREFIX}/fine.stl", "y")
      scan!

      assert_equal 1, files.count
      assert @user.nodes.find_by(storage_path: "fine.stl")
    end

    # ------------------------------------------- LANDMINE 7: one rel_path claimed by both kinds

    # The observer's own half. `files` and `dirs` are built as two collections with no shared key,
    # but `rel_path` IS the Reconciler's key, so this asserts the emitted SET, not just that the
    # dir is present -- "both were emitted" is exactly the defect and both-present passes it.
    test "one rel_path never yields two observations — the file is dropped, the directory stays" do
      @fake.seed!("#{PREFIX}/cad", "an object at a prefix's own key")
      @fake.seed!("#{PREFIX}/cad/x.stl", "its child")

      obs = Library::S3Observer.new(@user, adapter: adapter).observe

      dupes = obs.group_by(&:rel_path).select { |_, v| v.size > 1 }
      assert_empty dupes, "no rel_path may carry two observations: #{dupes.keys.inspect}"
      cad = obs.select { |o| o.rel_path == "cad" }
      assert_equal 1, cad.size
      assert cad.first.dir, "the DIRECTORY is what survives — dropping it instead would leave " \
                            "parent_id_for resolving 'cad' to a file node and parenting every " \
                            "descendant to a file"
    end

    # The ancestor case, which the single-level fixture cannot reach: the colliding path is a
    # DERIVED ancestor ("a/b" from the key "a/b/c/d.stl"), not the immediate parent, and the chain
    # below it must survive intact.
    test "a collision on a derived ancestor drops the file and keeps the whole dir chain" do
      @fake.seed!("#{PREFIX}/a/b", "an object at an ancestor's key")
      @fake.seed!("#{PREFIX}/a/b/c/d.stl", "a grandchild")
      scan!

      assert_equal %w[a a/b a/b/c a/b/c/d.stl],
                   @user.nodes.present.order(:storage_path).pluck(:storage_path)
      assert_equal %w[dir dir dir file],
                   @user.nodes.present.order(:storage_path).pluck(:kind)
    end

    # THE TEST THAT CATCHES REGRESSION, and the reason it is end-to-end rather than observer-level.
    # Before the filter this oscillated forever -- four UPDATEs every pass, net state unchanged --
    # while `cad/x.stl` stayed LIVE beneath a TOMBSTONED dir node: unreachable from the tree and
    # never repaired. Asserting "three nodes exist" would pass in both worlds; what has to be
    # asserted is that the child's parent resolves to a LIVE directory.
    test "a dir/file collision is stable across passes and the child keeps a live parent" do
      @fake.seed!("#{PREFIX}/cad", "an object at a prefix's own key")
      @fake.seed!("#{PREFIX}/cad/x.stl", "its child")
      scan!

      before = @user.nodes.order(:id).pluck(:id, :storage_path, :kind, :deleted, :parent_node_id)
      scan!
      after = @user.nodes.order(:id).pluck(:id, :storage_path, :kind, :deleted, :parent_node_id)
      assert_equal before, after, "the second pass must write nothing — this oscillated forever"

      child = @user.nodes.find_by!(storage_path: "cad/x.stl")
      assert_not child.deleted
      parent = @user.nodes.find_by!(node_id: child.parent_node_id)
      assert_equal "dir", parent.kind
      assert_not parent.deleted, "the child's parent must be LIVE — a tombstoned parent makes it " \
                                 "unreachable from the tree, silently and permanently"
    end

    # The dropped object is not indexed, and only this line says so — the standing objection at
    # ObjectIdentity's ladder is an object silently never indexed, so it must not be silent.
    test "the dropped object is warned about once, with a count and a sample key" do
      @fake.seed!("#{PREFIX}/cad", "dropped")
      @fake.seed!("#{PREFIX}/cad/x.stl", "kept")

      log = capture_log { scan! }

      assert_match(/WARN .*1 object\(s\) share a key with a directory prefix/, log)
      assert_match(/"cad"/, log)
      assert_nil @user.nodes.find_by(storage_path: "cad", kind: "file"),
                 "the object is genuinely not indexed — that is what the warning is for"
    end

    # THE STATED SUB-CASE, pinned because it is a DECISION and not a side effect: an empty `cad/`
    # marker beside a real `cad` object. Before the filter the FILE survived here; now the
    # directory does, and a real object goes unindexed with only a log line. Recorded so a future
    # reader meets the choice rather than discovering it.
    test "marker-only collision: the directory wins and the object is dropped — a flip, stated" do
      @fake.seed!("#{PREFIX}/cad/", "")
      @fake.seed!("#{PREFIX}/cad", "a real object")
      scan!

      node = @user.nodes.present.find_by!(storage_path: "cad")
      assert_equal "dir", node.kind
      assert_equal 1, @user.nodes.present.count
    end

    # ---------------------------------------------------------------- OS-generated clutter

    # OS clutter is never indexed, exactly as on the share walk — the same Library::OsClutter
    # predicate drives both observers and both adapters' observable! guards. An object named
    # `.DS_Store`, `._*`, or living under a `__MACOSX/`/volume-metadata prefix is skipped in the
    # observer, which is what keeps it out of `vanished_paths` and off the tombstoner.
    test "OS clutter is never indexed — .DS_Store, ._*, __MACOSX subtree, volume metadata" do
      @fake.seed!("#{PREFIX}/.DS_Store", "finder junk")
      @fake.seed!("#{PREFIX}/cad/.DS_Store", "junk at depth")
      @fake.seed!("#{PREFIX}/._resource", "an AppleDouble fork")
      @fake.seed!("#{PREFIX}/cad/._bracket.stl", "an AppleDouble fork at depth")
      @fake.seed!("#{PREFIX}/__MACOSX/junk.txt", "from a zip extraction")
      @fake.seed!("#{PREFIX}/__MACOSX/nested/more.txt", "the subtree nests")
      @fake.seed!("#{PREFIX}/.Spotlight-V100/store.db", "macOS volume metadata")
      @fake.seed!("#{PREFIX}/cad/bracket.stl", "a real file")
      scan!

      # Only the real dir and the real file — no clutter file, and no synthesized `__MACOSX` or
      # `.Spotlight-V100` directory node.
      assert_equal [ "cad", "cad/bracket.stl" ], @user.nodes.present.order(:storage_path).pluck(:storage_path)
    end

    # THE TRANSITION. A bucket indexed before the ignore-list existed carries a few clutter nodes.
    # On the first scan after the list lands they are no longer observed, so they tombstone
    # cleanly, and at that small fraction the mass-deletion guard proceeds rather than refusing.
    # If the ignore-list were NOT wired the clutter objects would be observed, re-pair by path, and
    # survive — so this doubles as a regression guard on the skip.
    test "existing indexed clutter tombstones on the next scan, and does not trip the guard" do
      50.times { |i| @fake.seed!("#{PREFIX}/real#{i}.stl", "body-#{i}") }
      scan!
      assert_equal 50, files.count

      @fake.seed!("#{PREFIX}/.DS_Store", "finder junk")
      @fake.seed!("#{PREFIX}/__MACOSX/junk.txt", "from a zip")
      clutter = [
        @user.nodes.create!(node_id: SecureRandom.uuid, name: ".DS_Store", kind: "file",
                            deleted: false, storage_path: ".DS_Store", parent_node_id: nil,
                            size: 1, mtime: 1, content_hash: "md5:deadbeef"),
        @user.nodes.create!(node_id: SecureRandom.uuid, name: "junk.txt", kind: "file",
                            deleted: false, storage_path: "__MACOSX/junk.txt", parent_node_id: nil,
                            size: 1, mtime: 1, content_hash: "md5:deadbeef")
      ]

      assert_nothing_raised { scan! }

      clutter.each do |n|
        assert @user.nodes.find_by!(node_id: n.node_id).deleted,
               "#{n.storage_path} is now clutter and must be tombstoned"
      end
      assert_equal 50, files.count, "no real object was touched"
      assert_nothing_raised { scan! } # stable on the next pass — no wedge
    end

    # ---------------------------------------------------------------- a repo's own metadata

    # THE SKIP THAT KEEPS ITS ENTRY, and on this backend the entry has to be INVENTED. The Scanner
    # observes a real `.git` directory and merely declines to descend; S3 has no directories at
    # all, so the marker exists only as a prefix of the very keys being dropped. Lose it and the
    # working-tree question has two answers across backends (§14a) and Maker::AttachToProject's
    # :in_working_tree silently stops firing on an s3 deployment.
    test ".git becomes ONE synthesized dir node and its keys are dropped" do
      @fake.seed!("#{PREFIX}/firmware/.git/config", "[core]")
      @fake.seed!("#{PREFIX}/firmware/.git/objects/ab/cdef", "a loose object")
      @fake.seed!("#{PREFIX}/firmware/main.cpp", "int main(){}")
      scan!

      assert_equal [ "firmware", "firmware/.git", "firmware/main.cpp" ],
                   @user.nodes.present.order(:storage_path).pluck(:storage_path),
                   "the marker and the working tree, and nothing from inside the repo"
      assert_equal "dir", @user.nodes.find_by!(storage_path: "firmware/.git").kind,
                   "S3 has no directories, so the marker must be SYNTHESIZED as a dir node"
      assert_equal 1, files.count, "main.cpp is the only file — no config, no loose objects"
    end

    # THE ORDER OF THE TWO BRANCHES, pinned. A zero-byte folder object inside the repo reaches
    # #observe as a directory MARKER, and the marker branch merges its whole ancestor chain — so
    # checked in the other order this key would mint a dir node BENEATH `.git`, which is the very
    # content the skip exists to drop.
    test "a directory-marker object INSIDE the repo does not mint a node beneath the marker" do
      @fake.seed!("#{PREFIX}/firmware/.git/objects/", "")
      @fake.seed!("#{PREFIX}/firmware/main.cpp", "int main(){}")
      scan!

      assert_equal [ "firmware", "firmware/.git", "firmware/main.cpp" ],
                   @user.nodes.present.order(:storage_path).pluck(:storage_path)
    end

    # A DIRECTORY, NEVER A FILE — ON THIS BACKEND TOO, which takes one deliberate term
    # (`metadata_dir != rel`) because a flat keyspace permits an OBJECT exactly at the marker path.
    # That object is what a submodule or a linked worktree writes: a small `gitdir:` POINTER FILE
    # where a plain repo has a directory. The Scanner holds an lstat, sees a file, and indexes it;
    # without the term this backend would call it the marker and drop its bytes, which is §14a's
    # one-condition-two-answers. The share-side half of this pair is in scanner_test.rb.
    test "a .git OBJECT is a FILE, like the Scanner's, not a synthesized marker" do
      @fake.seed!("#{PREFIX}/sub/.git", "gitdir: ../.git/modules/sub")
      @fake.seed!("#{PREFIX}/sub/main.c", "int main(){}")
      scan!

      node = @user.nodes.find_by!(storage_path: "sub/.git")
      assert_equal "file", node.kind, "a `gitdir:` pointer is a file, and its bytes are the point"
      assert_equal 2, files.count, "the pointer and main.c — nothing dropped"
    end

    # Whole segments, never prefixes — and the fixture has to be at DEPTH for this to be able to
    # fail. An earlier version seeded only `.gitignore` at the library root, where a segment-PREFIX
    # match still resolves the marker prefix to the key ITSELF, so `internal?` answers false and
    # the key survives anyway: the test passed under the very mutation it named. `.github/` is the
    # honest fixture — a directory a real code library HAS, beginning with the marker's own name —
    # and the assertion is on the LEAF, because a prefix match keeps the `.github` dir node while
    # silently dropping everything under it.
    test "a key merely NAMED like git metadata is indexed normally, at any depth" do
      @fake.seed!("#{PREFIX}/.gitignore", "tmp/")
      @fake.seed!("#{PREFIX}/.github/workflows/ci.yml", "on: push")
      @fake.seed!("#{PREFIX}/notes/git/todo.txt", "not a repo")
      scan!

      assert @user.nodes.find_by(storage_path: ".gitignore")
      assert @user.nodes.find_by(storage_path: ".github/workflows/ci.yml"),
             "a prefix match would drop this and leave `.github` a childless dir node"
      assert @user.nodes.find_by(storage_path: "notes/git/todo.txt")
    end

    # ---------------------------------------------------------------- LANDMINE 6: non-UTF-8 keys

    # PLAN DRIFT, VERIFIED, AND THE PLAN'S TEST IS IMPOSSIBLE AS WRITTEN.
    #
    # The plan seeds `"#{PREFIX}/bad\xFF.stl".b` into the fake and asserts `assert_nothing_raised
    # { scan! }`, expecting the observer's skip to swallow it. It cannot: the key never reaches the
    # observer. `Aws::S3::Plugins::Http200Errors#check_for_error` force_encodes the WHOLE response
    # body to UTF-8 and `match?`es it for "<Error>", so one bad byte anywhere in the listing raises
    # out of `list_objects_v2` itself. Verified against aws-sdk-s3 1.226.0, with the backtrace, and
    # it is NOT a stub artifact: `normalize_encoding` force_encodes any ASCII-8BIT body, and an
    # ASCII-8BIT body is exactly what a real wire response is.
    #
    # So the honest answer is not to skip the key -- we never get the key -- but to refuse the page.
    # A bare ArgumentError would abort too (nothing is reconciled either way), so the value of
    # catching it is the DIAGNOSIS: "one or more keys are not valid UTF-8" is actionable, "invalid
    # byte sequence in UTF-8" thrown from inside a gem is not.
    #
    # Both key shapes are covered because they fail by DIFFERENT doors, and only one of them is
    # real: a UTF-8-tagged invalid key raises ArgumentError from the SDK's own http_200_errors
    # plugin (the production path), while the plan's ASCII-8BIT key raises
    # Encoding::UndefinedConversionError from the stub's serializer (hermetic-test-only). Asserting
    # only the plan's shape would pin the fake's behavior and miss the SDK's.
    {
      "tagged UTF-8 (what a real wire response yields)" => "#{PREFIX}/bad\xFF.stl".dup.force_encoding("UTF-8"),
      "tagged binary (the plan's fixture)"              => "#{PREFIX}/bad\xFF.stl".b
    }.each do |shape, bad_key|
      test "a non-UTF-8 key -- #{shape} -- refuses the scan rather than bricking it silently" do
        @fake.seed!("#{PREFIX}/good.stl", "fine")
        scan!
        assert_equal 1, files.count

        @fake.objects[bad_key] = @fake.objects["#{PREFIX}/good.stl"]

        error = assert_raises(Library::Scanner::UnsafeScan) { scan! }
        assert_match(/not valid UTF-8/, error.message)
        assert_equal 1, files.count, "a listing we could not decode must never tombstone anything"
      end
    end

    # Pins the SDK behavior the tests above rest on, directly, so the day aws-sdk-s3 changes it we
    # find out here rather than by the observer's rescue quietly becoming dead code. ArgumentError
    # is the SDK's real one; EncodingError is the stub serializer's. Both are caught; neither is
    # a ServiceError, which is why the rescue needs them named at all.
    test "aws-sdk-s3 itself raises on a listing containing a non-UTF-8 key" do
      @fake.seed!("#{PREFIX}/good.stl", "fine")
      @fake.objects["#{PREFIX}/bad\xFF.stl".dup.force_encoding("UTF-8")] =
        @fake.objects["#{PREFIX}/good.stl"]

      error = assert_raises(ArgumentError) do
        @fake.client.list_objects_v2(bucket: "b", prefix: "#{PREFIX}/")
      end
      assert_match(/invalid byte sequence/, error.message)
      assert_not_kind_of Aws::S3::Errors::ServiceError, error,
                         "if this ever becomes a ServiceError the observer's rescue order matters"
    end

    # A listing client the SDK cannot be made to be: it hands back a key the SDK would have raised
    # on. This is the ONLY way to reach the observer's own valid_encoding? skip, which is defence
    # in depth for a client other than aws-sdk-s3 (`client:` is an injection seam) or an SDK that
    # stops raising. Without this the skip is untested code that looks tested.
    class RawKeyListing
      Object_  = Struct.new(:key, :size, :etag, :last_modified)
      Response = Struct.new(:contents, :is_truncated, :next_continuation_token)

      def initialize(keys) = @keys = keys

      def list_objects_v2(**)
        Response.new(@keys.map { |k| Object_.new(k, 1, %q("0cc175b9c0f1b6a831c399e269772661"),
                                                 Time.at(1_700_000_000)) }, false, nil)
      end
    end

    # BOTH TAGS, and the binary one is the whole reason this test exists. `valid_encoding?` -- the
    # Scanner's line, which looks like it transfers verbatim -- asks whether the bytes are valid in
    # the encoding the String is TAGGED with, and an ASCII-8BIT string is ALWAYS valid: every byte
    # sequence is legal binary. The Scanner is safe because Dir.children tags names UTF-8; a client
    # is under no such obligation. The naive check waved "bad\xFF.stl".b straight through into
    # storage_path, and this fixture is what caught it.
    [ [ "tagged UTF-8", "#{PREFIX}/bad\xFF.stl".dup.force_encoding("UTF-8") ],
      [ "tagged binary", "#{PREFIX}/bad\xFF.stl".b ] ].each do |shape, bad_key|
      test "the observer skips a non-UTF-8 key (#{shape}) handed to it directly, and keeps the others" do
        client = RawKeyListing.new([ "#{PREFIX}/good.stl", bad_key ])
        observer = Library::S3Observer.new(@user, adapter: adapter(client:))

        observed = nil
        assert_nothing_raised { observed = observer.observe }

        assert_equal [ "good.stl" ], observed.reject(&:dir).map(&:rel_path),
                     "one unindexable key must not lose the others, and must not be tombstoned"
      end
    end

    # A key whose bytes ARE valid UTF-8 but arrives tagged binary is a real object with a real
    # name, and must be indexed -- as a UTF-8 String, not a binary one, or storage_path carries a
    # binary blob into a text column. The skip above must not overreach into this.
    test "a binary-tagged key whose bytes are valid UTF-8 is indexed, re-tagged as UTF-8" do
      client = RawKeyListing.new([ "#{PREFIX}/café.stl".b ])
      observed = Library::S3Observer.new(@user, adapter: adapter(client:)).observe.reject(&:dir)

      assert_equal [ "café.stl" ], observed.map(&:rel_path)
      assert_equal Encoding::UTF_8, observed.first.rel_path.encoding
    end

    # ---------------------------------------------------------------- LANDMINE 4: partial listings

    # The fake paginates at 2 keys a page, so this really does cross page boundaries.
    test "paginates: every object across several pages is indexed" do
      7.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "body-#{i}") }
      scan!

      assert_equal 7, files.count, "a listing that stops at page 1 silently loses the rest"
      assert_operator @fake.calls[:list_objects_v2], :>, 1, "the fixture must cross a page boundary"
    end

    # THE LANDMINE-4 TEST, and the one the mutation is run against.
    #
    # A listing that fails on the LAST page of a long one is the realistic shape, and it is the
    # shape the mass-deletion guard CANNOT save us from: 18 of 20 files are observed, the missing 2
    # are 10% of the library, that is under the 20% threshold, and the guard waves it through. The
    # observer's abort is the only thing between the user and two silently tombstoned files.
    #
    # This is deliberately NOT the plan's fixture (see below): faulting page 1 yields zero
    # observations, which trips the guard by itself, so the plan's version passes with the abort
    # deleted. Here, deleting the abort tombstones 2 files and both assertions fail.
    test "a listing that fails mid-pagination ABORTS, under a threshold the guard would allow" do
      20.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "body-#{i}") }
      scan!
      assert_equal 20, files.count

      # 10 pages at 2 keys each; let 9 through and kill the 10th. 18 observed, 2 "vanished" = 10%,
      # comfortably under the default 20% guard.
      @fake.fault_after!(:list_objects_v2, 9, "InternalError")

      assert_raises(Library::Scanner::UnsafeScan) { scan! }

      @fake.clear_faults!
      assert_equal 20, files.count, "a partial listing must never be mistaken for a deletion"
    end

    # The plan's fixture, with the guard TAKEN OUT OF THE WAY. As the plan wrote it (default
    # threshold) this passes whether or not the observer aborts -- zero observations trip the
    # mass-deletion guard, which raises the same UnsafeScan from a different place for a different
    # reason. max_delete_pct: 100 disables the guard, so the only thing that can raise here is the
    # observer, and the only thing that can save the 6 files is its abort.
    test "a listing that fails on its FIRST page aborts on its own, without the guard's help" do
      6.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "body-#{i}") }
      scan!(max_delete_pct: 100)
      assert_equal 6, files.count

      @fake.fault!(:list_objects_v2, "InternalError")
      assert_raises(Library::Scanner::UnsafeScan) { scan!(max_delete_pct: 100) }

      @fake.clear_faults!
      assert_equal 6, files.count
    end

    # "There is more, and no, you may not have it." Real S3 cannot answer this way; an
    # S3-COMPATIBLE store is not bound by that, and the result is an incomplete listing wearing a
    # success. The SDK cannot be stubbed into it, so the client is hand-rolled.
    class TruncatedWithoutToken
      Response = Struct.new(:contents, :is_truncated, :next_continuation_token)
      def list_objects_v2(**) = Response.new([], true, nil)
    end

    test "a listing that is truncated but gives no continuation token aborts" do
      observer = Library::S3Observer.new(@user, adapter: adapter(client: TruncatedWithoutToken.new))
      error = assert_raises(Library::Scanner::UnsafeScan) { observer.observe }
      assert_match(/continuation token/, error.message)
    end

    # ---------------------------------------------------------------- wired to the real decider

    # The mass-deletion guard is the RECONCILER's, and this proves the observer is actually wired
    # to it rather than reimplementing a laxer one of its own.
    test "a genuinely emptied bucket trips the mass-deletion guard" do
      3.times { |i| @fake.seed!("#{PREFIX}/g#{i}.stl", "x#{i}") }
      scan!
      @fake.objects.clear

      assert_raises(Library::Scanner::UnsafeScan) { scan! }
      assert_equal 3, files.count
    end

    # THE PHASE'S HEADLINE PROMISE, through the real observer: a reorganization in the bucket keeps
    # the node_id, so every project attachment, BOM link and tag on that file survives it.
    test "a rename in the bucket keeps the node_id -- the attachment survives" do
      @fake.seed!("#{PREFIX}/old.stl", "same bytes")
      scan!
      id = @user.nodes.find_by!(storage_path: "old.stl").node_id

      body = @fake.objects.delete("#{PREFIX}/old.stl")
      @fake.objects["#{PREFIX}/cad/new.stl"] = body
      scan!(max_delete_pct: 100)

      assert_equal id, @user.nodes.find_by!(storage_path: "cad/new.stl").node_id
    end

    # ---------------------------------------------------------------- the unpairable warning
    #
    # The other half of the headline promise: where it does NOT hold, say so. An `etag:` identity is
    # rung 3 -- not content-determined -- so a move of that object cannot pair and its attachments
    # re-point. Nothing else in the system would ever mention it, which is what makes this advisory
    # the feature rather than a log line.
    #
    # Asserted on the LOG, deliberately, because the log IS the feature: a `count` reader exposed
    # for a test would prove only that we can count, which is what the method did for a whole phase
    # while the diagnostic its comment promised did not exist.

    test "a bucket with multipart ETags warns once, with the count and the consequence" do
      2.times { |i| @fake.seed!("#{PREFIX}/big#{i}.stl", "x#{i}", etag: "#{'a' * 32}-#{i + 2}") }
      @fake.seed!("#{PREFIX}/small.stl", "single-part")

      log = capture_log { scan! }

      # The COUNT, not merely that something was said: it names the 2 multipart objects and not the
      # single-part one beside them.
      assert_match(/\b2 object\(s\)/, log)
      # ONE line, however many objects -- a bucket this backend targets holds millions.
      assert_equal 1, log.scan(/no content-determined identity/).length
      # In the operator's terms. "not content-determined" is our vocabulary; what they need to know
      # is that renaming these breaks the attachments on them.
      assert_match(/renaming/, log)
      assert_match(/attachment/, log)
      assert_match(/WARN/, log, "it is a promise the operator was made and is not getting")
    end

    # ADVISORY, not a gate. The objects are indexed exactly like any other -- only their moves are
    # invisible. Refusing to index them would deny the user a library to punish their storage class.
    test "an unpairable object is still indexed like any other" do
      @fake.seed!("#{PREFIX}/big.stl", "hello", etag: "#{'a' * 32}-7")
      scan!

      node = @user.nodes.find_by!(storage_path: "big.stl")
      assert_equal 5, node.size
      assert_equal "etag:#{'a' * 32}-7", node.content_hash
    end

    # SILENT WHEN THERE IS NOTHING TO SAY. A warning that fires on every scan of every healthy
    # bucket is a warning nobody reads by the time a real one arrives.
    test "an all-single-part bucket says nothing" do
      3.times { |i| @fake.seed!("#{PREFIX}/s#{i}.stl", "x#{i}") }

      log = capture_log { scan! }

      assert_no_match(/content-determined/, log)
    end

    # ---------------------------------------------------------------- what a scan costs

    # The identity is FREE in the listing, so the observer must never HEAD or GET to get it. A HEAD
    # per object is a billed request per object on EVERY scan (every 15 minutes, forever); a GET
    # per object is a full egress of the bucket. That cost is the exact thing the "point it at my
    # existing storage" on-ramp exists to avoid.
    test "a scan costs listings only -- no HEAD, no GET" do
      5.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "x#{i}") }
      scan!

      assert_equal 0, @fake.calls[:head_object], "a HEAD per object is a bill on every scan"
      assert_equal 0, @fake.calls[:get_object], "a GET per object is an egress of the bucket"
    end

    # The other half of the same promise, and the one that would actually bite: the Reconciler
    # hashes LAZILY by default, so an observation arriving WITHOUT a content_hash makes it read the
    # bytes to compute one. Every file observation must carry its identity, or indexing a bucket
    # means downloading it. S3Observer::NEVER_READ is the production tripwire for this; this
    # asserts the condition that keeps it from ever firing.
    test "every file observation carries its own identity, so the reader is never needed" do
      @fake.seed!("#{PREFIX}/a.stl", "x")
      @fake.seed!("#{PREFIX}/cad/b.stl", "y")

      observed = Library::S3Observer.new(@user, adapter: adapter).observe
      observed.reject(&:dir).each do |o|
        assert o.content_hash.present?, "#{o.rel_path} has no identity -- the Reconciler would GET it"
      end
    end

    test "the reader the observer hands the Reconciler raises rather than silently downloading" do
      assert_raises(RuntimeError) { Library::S3Observer::NEVER_READ.call("a.stl") }
    end

    # ---------------------------------------------------------------- unreadable_dirs

    # ALWAYS [], and it is a CLAIM the Reconciler requires be made out loud: "the listing was
    # complete". It is true because the only two outcomes are complete (nothing unobserved) and
    # aborted (nothing reconciled) -- never partial. ScanJob reads this off the observer exactly as
    # it reads it off the Scanner.
    test "unreadable_dirs is empty, because a listing is complete or it is not a listing" do
      @fake.seed!("#{PREFIX}/a.stl", "x")
      assert_equal [], scan!.unreadable_dirs
    end

    test "call returns the observer, mirroring Scanner.call" do
      @fake.seed!("#{PREFIX}/a.stl", "x")
      assert_kind_of Library::S3Observer, scan!
    end

    private

    # Same idiom as ScanJob's suite: the warning is a real Rails.logger line, so read it there
    # rather than through a seam invented for the test.
    #
    # The FORMATTER is the one addition, and it is not decoration: ActiveSupport::Logger's default
    # writes the message alone, so the severity never reaches `io` and an assertion on the LEVEL
    # would be unfalsifiable -- `warn` and `info` produce identical output. Downgrading this
    # advisory to info is exactly the regression worth catching, so the level has to be visible.
    def capture_log
      io = StringIO.new
      prior = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      Rails.logger.formatter = ->(severity, _time, _progname, msg) { "#{severity} #{msg}\n" }
      yield
      io.string
    ensure
      Rails.logger = prior
    end
  end
end
