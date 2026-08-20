require "test_helper"
require "ripper"

# Executes the two "standing tripwire greps" that CLAUDE.md cites as PROOFS of the maker/file-layer
# boundary (§14a, §14c) and of the capability-gate design (§14a).
#
# WHY THIS FILE EXISTS. Until now both were prose. Nothing ran them, and one had already drifted
# undetected: it read "returns nothing" for months after the addon framework made the true answer
# "exactly one hit, and it is library_output.rb" — corrected only when a fresh reader happened to
# type the command. A proof nobody runs is a comment. Same pattern as ci_hygiene_test.rb and
# deploy_hygiene_test.rb: guard the facts no other test can see.
#
# Implemented by READING FILES, not by shelling out to grep — the same choice deploy_hygiene_test.rb
# makes when it parses YAML instead of grepping it. No shell, no BSD/GNU differences, and the
# comment-stripping becomes explicit instead of riding on a fragile `grep -v ':[0-9]*: *#'`.
class ArchitectureInvariantsTest < ActiveSupport::TestCase
  ROOT = Rails.root

  # Lines of real code (not comments) matching `pattern`, as "path:lineno" strings.
  #
  # Skipping comment lines is LOAD-BEARING, not tidiness. Both greps below have comments in-tree
  # that *describe* the coupling they forbid, so the un-filtered form has never returned what the
  # docs claim — which is precisely how the drift went unnoticed. This only strips whole-line
  # comments, matching `grep -v ':[0-9]*: *#'`; a trailing comment on a code line still counts, and
  # should, because the code on it is real.
  def offending(globs, pattern)
    Array(globs).flat_map { |rel| Dir.glob(ROOT.join(rel, "**", "*.rb")) }.sort.flat_map do |file|
      File.readlines(file, chomp: true).each_with_index.filter_map do |line, idx|
        next if line.lstrip.start_with?("#")
        next unless line.match?(pattern)
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}"
      end
    end
  end

  # Real `Sync::Something` CODE references in `file` -- constant-path token pairs read off
  # Ripper's own lexer, not a text match. A text pattern like /Sync::/ cannot tell a real
  # reference from the same nine characters sitting inside a STRING:
  # app/jobs/library/trash_purge_job.rb's own ArgumentError message names "Sync::Gc" and
  # "Sync::ChunkReaper" in PROSE, for an operator reading a failed-job log -- a bare regex
  # against that file finds two hits, both inside the string, zero of them real (verified before
  # writing this method). Ripper's lexer emits string content as :on_tstring_content and comment
  # bodies as :on_comment, never as :on_const, so a real reference and the same text sitting
  # inside a string or a comment are STRUCTURALLY different token types and cannot be confused,
  # however the string is quoted or how many lines it spans. This SUBSUMES `offending`'s
  # hand-rolled comment strip above rather than duplicating it with a second, weaker mechanism --
  # and it additionally closes a hole that helper never had to face, because nothing in the
  # chunk-internals grep above happens to collide with a string literal the way "Sync::" does.
  # ANY REAL `Sync` CONSTANT COUNTS -- deliberately NOT "a `Sync` followed by `::`", which is what
  # this method required until a review demonstrated the miss. `Sync.load_manifests` and
  # `Sync.load_version_sizes` are real public singleton methods on the module itself
  # (app/services/sync.rb), and `Sync.load_manifests(...)` lexes as :on_const + :on_period -- so a
  # maker-layer file calling one sailed straight through, GREEN, while reaching into the sync
  # engine every bit as much as `Sync::Commit` does. The adjacency rule also missed `Sync ::Commit`
  # across a line break, for the same structural reason.
  #
  # Dropping the pairing costs nothing and is also the more honest question: there is no legitimate
  # reason for maker-layer code to name the bare `Sync` constant at all outside the one allowed
  # door, so "does this file mention Sync?" IS the invariant, and the narrower version was an
  # implementation detail masquerading as one. Verified against the whole live tree before and
  # after -- identical offending-file set, identical hit lines, no new noise.
  #
  # WIDENED TO THE BARE ENGINE MODEL NAMES TOO (ENGINE_MODELS, below) -- Stage 3a Task 1. The
  # engine's own AR models are bare top-level constants, not namespaced under `Sync::`, so
  # everything argued above about the `Sync` token applies to each of them independently: a
  # maker-layer file doing `Version.find(...)` reaches into the engine exactly as much as one
  # calling `Sync::Commit`, and until this widening the guard could not see it at all -- that blind
  # spot is how the Stage 3 boundary design's findings stayed invisible long enough to need a whole
  # separate document (its §9: "Stage 3 must widen both [guards] to the bare model names, or its
  # own boundary will be unenforced in exactly the way this document had to be written to
  # discover").
  def sync_references(file)
    rel = Pathname.new(file).relative_path_from(ROOT)
    Ripper.lex(File.read(file)).filter_map do |(pos, type, str, _)|
      next unless type == :on_const
      "#{rel}:#{pos.first}" if str == "Sync" || ENGINE_MODELS.include?(str)
    end
  end

  # SEVEN MODELS MOVE TO THE ENGINE (Stage 3a plan premises; boundary design §3): Version, Chunk,
  # ManifestChunk, PendingCommit, ChangelogEntry, Conflict, FileLock. Only SIX are listed below --
  # `Chunk` is deliberately absent, and not for the same reason `Device` is (next paragraph). It is
  # a TOKENIZATION problem, not a policy one. `FileLayer::Chunk` (CLAUDE.md §14a's one sanctioned
  # adapter) is a DIFFERENT class from the `Chunk` AR model, and Ripper lexes a qualified reference
  # to it as three separate tokens -- on_const "FileLayer", on_op "::", on_const "Chunk" -- so the
  # bare on_const "Chunk" this detector matches is structurally indistinguishable, from tokens
  # alone, between a real AR-model reference and the tail of a fully-qualified adapter reference.
  # This is not hypothetical: `FileLayer.build`'s own factory (app/services/file_layer.rb:120)
  # writes `when "chunk" then Chunk.new` *inside* `module FileLayer`, where Ruby's lexical constant
  # lookup resolves the bare `Chunk` to `FileLayer::Chunk` -- a legitimate, load-bearing reference,
  # in the file that IS the port, that a naive widening would flag as a violation. Scoping the
  # check to files outside `app/services/file_layer/` does not close this either: `file_layer.rb`
  # itself sits one level ABOVE that directory, so a directory-based scope misses the exact line
  # that motivates it, and would still miss any future `FileLayer::Chunk` reference written
  # elsewhere in the tree -- the ambiguous token is the same regardless of which file it appears
  # in. Dropping `Chunk` costs nothing real: verified by lexing every file under `app/` for a bare
  # on_const "Chunk" token, the only hits anywhere are the AR model's own definition
  # (app/models/chunk.rb:1), the adapter's own class-opening line
  # (app/services/file_layer/chunk.rb:8), the `FileLayer.build` factory line above, and ONE genuine
  # AR-model cross-reference -- `Sync::Commit.upsert_chunks!`'s `Chunk.insert_all`
  # (app/services/sync/commit.rb:259) -- which is already sync-side via SYNC_SIDE_GLOBS below. No
  # maker-layer file references the bare `Chunk` AR model today, so omitting it from this set loses
  # no real coverage.
  #
  # `Device` IS ALSO DELIBERATELY ABSENT, for an unrelated reason -- this is the entry most likely
  # to be "fixed" by someone counting the eight moving tables (there are seven; Device stays,
  # boundary design §3). Device STAYS WITH THE HOST: its token is the only credential the whole v1
  # API accepts, including all fourteen v1/maker/* controllers, so an engine that owned it would
  # leave the maker API unable to authenticate a single request without the engine mounted. Adding
  # it here would flag app/controllers/application_controller.rb and
  # app/services/maker/addons/library_output.rb as violations for using a model that is
  # legitimately theirs.
  ENGINE_MODELS = %w[Version ManifestChunk PendingCommit ChangelogEntry Conflict FileLock].freeze

  test "the maker layer reaches for chunk internals in exactly one place, and that place is the addon output path" do
    # CLAUDE.md §14c. The maker layer must not know files are chunks — that is the whole point of
    # the FileLayer port. The ONE legitimate exception is addon-generated output, which has no
    # client to presign for: in chunk mode the server itself drives a single-chunk Sync::Commit plus
    # the put, mirroring what the web uploader does from the browser.
    #
    # The assertion is "one hit, and it is library_output.rb" — NOT "no hits". Asserting zero would
    # be asserting something false, and asserting only the count would let the coupling migrate to
    # some other file while the test stayed green.
    # The directory set is DERIVED FROM THE TREE — `app/**/maker` is every maker directory there
    # is — so a NEW `app/<x>/maker/` is covered the day it is created. It was a remembered list
    # of three and silently missed `app/controllers/v1/maker` + `app/models/concerns/maker` (15
    # files), where a ChunkStore call left this test GREEN over a live §14a breach — in the very
    # file §14a introduced to replace a remembered grep. Derive, don't enumerate: the same rule as
    # stimulus_hygiene_test.rb's registered_identifiers.
    hits = offending(%w[app/**/maker], /manifest_chunks|ChunkStore/)

    assert_equal 1, hits.size,
                 "expected exactly ONE chunk-internals reference in the maker layer, got #{hits.size}:\n" \
                 "  #{hits.join("\n  ")}\n" \
                 "A NEW one means the maker/file-layer split (CLAUDE.md §14a) has been breached — " \
                 "route the write through FileLayer#write or Sync::Commit instead. If the existing " \
                 "one MOVED, update this test and CLAUDE.md §14c together."
    assert_match %r{\Aapp/services/maker/addons/library_output\.rb:\d+\z}, hits.sole,
                 "the one permitted chunk-internals reference must live in " \
                 "Maker::Addons::LibraryOutput (the single addon output path), but it is at #{hits.sole}"
  end

  # Paths that are NOT "the maker layer" for THIS guard, and so are never scanned by it: the sync
  # engine's own service objects (moving to a separate repo in Stage 3, CLAUDE.md §10), the
  # device-facing v1 API (sync-shaped, not maker-shaped -- a device talks to it directly, never
  # through a maker controller), the two jobs that reclaim sync-engine state (chunk refcounts,
  # abandoned commits), the ActionCable channel that IS the sync nudge, and FileLayer::Chunk
  # itself, §14a's one legitimate door. GLOBS, not a file list, for the same reason the scanned
  # file set in the test below is Dir.glob'd rather than enumerated: a new file under any of
  # these trees is sync-side by construction, not a maker-layer file that happens to be exempt
  # today.
  # THE TWO REAPERS ARE SPELLED OUT, NOT MATCHED BY `app/jobs/*reaper*_job.rb`. That glob encoded a
  # NAMING coincidence rather than the real property ("reclaims sync-engine state"), which is the
  # `is_a?(FileLayer::Share)` mistake §14b records -- and a review demonstrated the hole: a new
  # top-level `app/jobs/bom_link_reaper_job.rb` full of maker-layer code would have been waved
  # through, silently, on the strength of its NAME. It excluded `app/jobs/maker/*_reaper_job.rb`
  # only by the accident that Dir.glob does not cross `/` without `**`. Two literal paths cost one
  # line each and cannot be widened by someone choosing a filename.
  # SIX OF THE SEVEN MOVING MODELS' OWN DEFINITION FILES ARE LISTED INDIVIDUALLY, ADDED IN STAGE 3a
  # TASK 1 FOR THE SAME REASON `app/services/file_layer/chunk.rb` IS: each opens with `class <Name>
  # < ApplicationRecord`, naming itself, and self-declaration is not the maker layer "reaching
  # into" the engine -- it IS the engine, exactly as `app/services/sync/**` is above. Left off this
  # list, ENGINE_MODELS's widened sync_references would flag six false positives that the Stage 3a
  # plan's own premise grep never had to face, because that grep excluded `app/models` wholesale
  # (`grep -v '^app/(...|models|...)'`) rather than naming files -- a shortcut that works for a
  # one-shot grep and not for a glob this test re-runs every time. `version.rb` additionally
  # references `ManifestChunk` internally (`:10`, `ManifestChunk.where(...)`), a legitimate
  # engine-to-engine reference the same exclusion covers, since it isn't a second file. `Chunk`'s
  # own model file (app/models/chunk.rb) needs NO entry here: `Chunk` is deliberately absent from
  # ENGINE_MODELS (see its comment above), so nothing in this file would ever match it regardless.
  SYNC_SIDE_GLOBS = %w[
    app/services/sync/**/*.rb
    app/services/sync.rb
    app/controllers/v1/**/*.rb
    app/jobs/chunk_reaper_job.rb
    app/jobs/pending_commit_reaper_job.rb
    app/jobs/retention_job.rb
    app/channels/**/*.rb
    app/services/file_layer/chunk.rb
    app/models/version.rb
    app/models/manifest_chunk.rb
    app/models/pending_commit.rb
    app/models/changelog_entry.rb
    app/models/conflict.rb
    app/models/file_lock.rb
  ].freeze

  # ONE FILE, NOT ZERO. app/services/sharing/links.rb:60 does `ManifestChunk.where(...)`
  # (Sharing::Links, the share-link redemption path) -- a real, uncorrected cross-boundary
  # reference, confirmed by running the widened detector against the whole tree (Stage 3a plan
  # premises; boundary design §1). It is not a bug to fix here: Stage 3a Task 6 moves share_links
  # -- model, service, and its two v1 controllers -- to the engine side, at which point this file
  # becomes sync-side by construction (already-existing `app/controllers/v1/**/*.rb` above covers
  # its controllers; the service needs its own entry) and this reference stops being a violation at
  # all. Naming it here rather than leaving Task 1 red is deliberate: it lands this task clean and
  # green today, while leaving a dated, findable trail for Task 6 to remove.
  #
  # THE LIST MUST DIE WITH ITS LAST ENTRY, NOT LINGER EMPTY -- see the test below for how.
  SYNC_SEAM_EXCEPTIONS = %w[
    app/services/sharing/links.rb
  ].freeze

  test "the maker layer reaches the sync engine through FileLayer::Chunk alone" do
    # CLAUDE.md §14d's tripwire, made real: "if a maker-layer change needs to touch sync, the
    # changelog, conflicts, locks, or the mounts, the boundary is wrong -- stop." Tasks 3-6 gave
    # FileLayer::Chunk all four metadata verbs specifically so the maker layer never has to reach
    # past the port for them again; Task 8 closed the last two call sites (FilesController's
    # begin_upload/finalize_upload and Maker::Addons::LibraryOutput's own upload, both now behind
    # FileLayer#begin_upload/#finalize_upload) -- so this was a flat assertion of the whole rule
    # rather than a count-and-name check against a shrinking allowlist, from Task 8 until Stage 3a.
    # (It was that allowlist until Task 8: SYNC_SEAM_EXCEPTIONS named exactly those two files while
    # the byte path was still in progress, and its own comment said to delete it, and simplify this
    # test to the one assertion below, the moment it emptied. That simplification held for one
    # stage.)
    #
    # STAGE 3a TASK 1 WIDENS THE DETECTOR, NOT THE RULE. `sync_references` now also matches the
    # bare engine model names (ENGINE_MODELS above), because `Version.find(...)` reaches into the
    # engine exactly as much as `Sync::Commit` does, and the guard was blind to it (Stage 3
    # boundary design §0, §9). That widening found exactly ONE real violation --
    # app/services/sharing/links.rb -- so SYNC_SEAM_EXCEPTIONS is back, in exactly its Task-8
    # shape and for the same kind of reason it existed then: the fix (Task 6, moving share_links to
    # the engine) is real, scoped work, not something to do inline inside a guard-widening task.
    sync_side = SYNC_SIDE_GLOBS.flat_map { |glob| Dir.glob(ROOT.join(glob)) }
    maker_layer_files = Dir.glob(ROOT.join("app", "**", "*.rb")) - sync_side

    hits = maker_layer_files.flat_map { |file| sync_references(file) }
    offending_files = hits.map { |hit| hit.split(":").first }.uniq.sort

    # NAMED, NOT COUNTED, in both directions -- a mutation that swaps one offender for another
    # while holding the count steady is caught only by asserting WHICH files, matching this file's
    # own "assert the files, not merely a count" rule from the chunk-internals test above.
    extra = offending_files - SYNC_SEAM_EXCEPTIONS # a NEW violation, not on the list
    stale = SYNC_SEAM_EXCEPTIONS - offending_files # a LISTED file that no longer violates

    assert_empty extra,
                 "NEW maker-layer file(s) reaching into Sync:: or a bare engine model directly, " \
                 "not on the exception list:\n  #{extra.join("\n  ")}\n" \
                 "Route this through FileLayer::Chunk instead (CLAUDE.md §14a/§14d). If this " \
                 "really is Task 6 (share_links) work in progress, add it to " \
                 "SYNC_SEAM_EXCEPTIONS and say so in the PR -- do not let this test go red " \
                 "silently past that."
    assert_empty stale,
                 "SYNC_SEAM_EXCEPTIONS lists file(s) that no longer reach into Sync:: or a bare " \
                 "engine model directly:\n  #{stale.join("\n  ")}\n" \
                 "Task 6 fixed this -- remove the entry. If SYNC_SEAM_EXCEPTIONS is empty once " \
                 "you do, remove the constant entirely and simplify this test's two assertions " \
                 "above to a single `assert_empty offending_files`."
    # THE LIST MUST DIE WITH ITS LAST ENTRY, NOT LINGER EMPTY. Without this, a dutiful editor
    # could shrink SYNC_SEAM_EXCEPTIONS to `[]` one fix at a time (the two assertions above stay
    # green the whole way) and leave it sitting there -- an allowlist for nothing, which the next
    # reader has to re-derive is pointless before trusting it. This fails THAT state too, so
    # whoever removes the last entry (Task 6) is told, in the same run, to delete the constant and
    # its comment, not just leave `[].freeze` behind.
    assert_not_empty SYNC_SEAM_EXCEPTIONS,
                     "SYNC_SEAM_EXCEPTIONS is empty, which means Task 6 is done: delete this " \
                     "constant and its comment, and simplify this test to `assert_empty " \
                     "maker_layer_files.flat_map { |file| sync_references(file) }`."
  end

  test "NotImplementedError is never rescued" do
    # CLAUDE.md §14a. The 501 for an unsupported backend op is a capability gate BEFORE the call,
    # never a rescue. Three reasons, all recorded at app/controllers/concerns/library_capabilities.rb:
    #
    #   1. NotImplementedError is a ScriptError, NOT a StandardError. A bare `rescue => e` and
    #      ActiveJob's `retry_on` therefore do not catch it at all. A rescue-based gate does not
    #      have a gap — it does not work, and fails to exactly the 500 the design forbids.
    #   2. A 501 from Chunk#write would be factually wrong: it means the CALLER used the wrong door,
    #      not that the deployment cannot accept uploads.
    #   3. A controller rescue catches it from anywhere below, laundering a real s3 MISCONFIGURATION
    #      at FileLayer.build into a routine-looking response.
    #
    # So it stays un-rescued and loud, and the capability gates are what keep it unreachable.
    hits = offending(%w[app lib], /rescue.*NotImplementedError/)

    assert_empty hits,
                 "NotImplementedError must never be rescued (CLAUDE.md §14a), found:\n" \
                 "  #{hits.join("\n  ")}\n" \
                 "It is a ScriptError, so this rescue does not do what it looks like it does. " \
                 "Gate on the capability before the call instead — see LibraryCapabilities."
  end

  test "every ApplicationController descendant requires a signed-in session" do
    # CLAUDE.md §14d: the web app is session-authed, and "every server-rendered page requires a
    # session" was stated sixteen times — once per controller — and enforced nowhere. A NEW
    # subclass, or one extracted from an existing controller, was public by default and nothing
    # went red. §15 records the sibling failure for `direct_uploads`; this is that shape from
    # inside `ApplicationController` rather than outside it.
    #
    # UNLIKE THE TWO GREPS ABOVE, THIS ONE READS THE CONSTANT GRAPH, NOT FILES — and that is the
    # point of it rather than a deviation from the file's style. A file scan cannot see the three
    # `Tools::*` controllers that INHERIT the callback from `Tools::BaseController` rather than
    # declaring it; cannot tell `app/controllers/users/*.rb` (Devise subclasses, which must NOT
    # have it) from an app controller; and once the base class carries the callback there is no
    # subclass line left on disk to read at all. Same derive-don't-enumerate rule the greps use
    # for their directory set, one layer up.
    #
    # THE DEVISE EXCLUSION IS DERIVED, NEVER A LIST. `Devise.parent_controller` defaults to
    # "ApplicationController", so `DeviseController` and all eleven of its subclasses ARE
    # descendants here — and sign-in, sign-up, confirm, reset and the OmniAuth callback must
    # stay anonymous or `/users/sign_in` redirects to itself. `<= DeviseController` answers for
    # a twelfth the day it appears.
    #
    # NOT COVERED, DELIBERATELY, AND BOTH ARE STATED SO NOBODY READS MORE INTO A GREEN RUN:
    #   * The `unless: :devise_controller?` half of the base-class callback — and NOTHING ELSE
    #     covers it either. Devise controllers are excluded from this set by construction, so
    #     nothing here can observe that arm; but neither can any other test, because Devise's own
    #     `authenticate_user!` already no-ops on `devise_controller?` internally, which makes the
    #     condition redundant today. Deleting it leaves the entire web suite green. The reasoning
    #     is at application_controller.rb, beside the line; do not add a test that asserts the
    #     condition is present, which would pin a spelling rather than a behaviour.
    #   * A `before_action :authenticate_user!, only: [:show]` on a subclass, which satisfies this
    #     assertion while leaving every other action open — a child's symbol declaration REPLACES
    #     the inherited conditional entry outright (CallbackChain#append_one deletes the duplicate
    #     before pushing), which is the same mechanism that makes the base-class callback a strict
    #     no-op while the subclass lines stand. Re-deriving each callback's conditions here would
    #     be a second, weaker copy of Rails' own filter logic; the answer if it ever matters is a
    #     request test, not more reflection.
    #   * `CspReportsController` and `DevBlobsController`, which descend from
    #     `ActionController::Base` on purpose — as does `ActiveStorage::BaseController`, so this
    #     guard would NOT have caught the `direct_uploads` hole §15 describes. That one is closed
    #     by the route shadow, not by this.
    Rails.application.eager_load!

    guarded = ApplicationController.descendants.reject { |klass| klass <= DeviseController }

    # Defeats a vacuous pass. Without eager loading — or if the Devise reject ever widened to
    # swallow the app's own controllers — `guarded` would be empty and the assertion below would
    # be green over nothing at all.
    assert_includes guarded, FilesController,
                    "the guarded set should contain the app's own controllers; got " \
                    "#{guarded.size} classes. Did eager loading fail, or did the Devise " \
                    "exclusion widen?"

    unprotected = guarded.reject { |klass|
      klass._process_action_callbacks.any? { |cb| cb.kind == :before && cb.filter == :authenticate_user! }
    }.map(&:name).sort

    assert_empty unprotected,
                 "every ApplicationController descendant must run `authenticate_user!` " \
                 "(CLAUDE.md §14d), but these do not:\n  #{unprotected.join("\n  ")}\n" \
                 "It is declared on ApplicationController for all of them, so a controller " \
                 "reaches this list only by a `skip_before_action :authenticate_user!` — or by " \
                 "that base-class declaration having been removed. A page that is genuinely " \
                 "public needs an argument here and in §14d, not a skip."
  end

  # THE TWO INDEXES ALLOWED TO BE A STRICT PREFIX OF ANOTHER, as "table" => "index name".
  #
  # Both are the SAME mechanism and neither is discoverable from a fixture, which is why they are
  # written down here rather than left for a future reader to rediscover: SQLite APPENDS THE ROWID
  # to every index key, so a narrow `(a)` index can seek `a = ? AND rowid <cmp> ?` and yield rows
  # already in id order. A composite `(a, b)` cannot — within the `a` group it is ordered by `b`,
  # so the planner adds `USE TEMP B-TREE FOR ORDER BY` and reads the whole group. The effect is
  # SCALE-DEPENDENT and invisible at fixture size; both entries cite a MEASUREMENT taken at
  # production scale, and a third candidate should not be added without one.
  #
  # TWO SCOPE LIMITS ON THAT MECHANISM, both of which a reader will otherwise assume away.
  #
  # It is SQLITE-ONLY. Postgres does not append the rowid to index keys, so neither ratio below
  # transfers and neither exemption is justified there — on PG these two would be droppable. The
  # entries stay because the deployment that pages a 200,000-node library is the SELF-HOST one,
  # which is SQLite (§7); do not read the numbers as adapter-neutral.
  #
  # And it is a NO-STATISTICS result. Re-measured at review: with `ANALYZE` run, the without-index
  # plan becomes `SEARCH nodes USING INTEGER PRIMARY KEY (rowid>?)` and the two reach PARITY. The
  # exemption still stands, because no-stats IS the production configuration — nothing in this repo
  # runs `ANALYZE` or `PRAGMA optimize`, and neither `storage/development.sqlite3` nor
  # `storage/test.sqlite3` contains `sqlite_stat1`. Said explicitly because
  # `app/services/maker/addon_origin.rb:64-69` already records the stance that "then just run
  # ANALYZE" is a misleading half-answer, and a measurement that depends on which side of that
  # line it sits on should say which side it sits on.
  #
  #   maker_addon_states — `app/services/maker/addon_origin.rb:114-119` records the probe: at 5,000
  #     states, from 4 ids up the plan is `SEARCH maker_addon_states USING INDEX
  #     index_maker_addon_states_on_user_id (user_id=? AND rowid=?)`.
  #
  #   nodes — `Sync::Tree.call` (`app/services/sync/tree.rb:12`) pages the DEVICE INITIAL SYNC with
  #     `where("id > ?", after).order(:id).limit(1000)`. Dropping this index turns each page from
  #     one early-terminating seek into a full read-and-sort of the user's node set, so a whole
  #     export goes from O(N) to O(N^2/limit). Measured on 200,000 nodes, twenty pages, warm cache:
  #     0.0163 s with the index against 2.9766 s without — 183x. (This line first said 30x, from a
  #     smaller run; a reviewer rebuilt it at scale and the gap was WIDER, not narrower. The index
  #     costs 249,856 bytes, 0.21% of the database.) `#find_each`/`#in_batches` page identically,
  #     so `Maker::Previews::MissingBackfill` rides the same seek — verified, not assumed.
  PREFIX_INDEX_EXEMPTIONS = {
    "maker_addon_states" => "index_maker_addon_states_on_user_id",
    "nodes" => "index_nodes_on_user_id"
  }.freeze

  test "no index's column list is a strict prefix of another index's on the same table" do
    # An index on `(a)` is redundant beside one on `(a, b)`: any seek the narrow one answers, the
    # wide one answers too. The narrow one still costs a btree write on every insert, update and
    # delete of the row, plus its own copy of the leading column on disk. These regrow silently —
    # `t.references :user, foreign_key: true` auto-indexes `user_id`, and a composite led by
    # `user_id` then gets added on top — which is exactly how ten of them accumulated before
    # `20260819120000_drop_redundant_prefix_indexes.rb`. Nothing else in the suite asserts anything
    # about indexes at all, so without this the next `t.references` puts one straight back.
    #
    # A PARTIAL SUPERSET DOES NOT COUNT, AND THAT EXCLUSION IS LOAD-BEARING. `nodes` carries
    # `(user_id, storage_path) WHERE deleted = false`; it cannot answer an unfiltered `user_id`
    # predicate, so treating it as a superset would license removing a prefix that nothing else
    # covers. The check therefore only reads NON-PARTIAL indexes as supersets — it can miss a
    # redundancy, never invent one, which is the safe direction for a guard whose output is read
    # as permission to delete.
    conn = ActiveRecord::Base.lease_connection
    pairs = conn.tables.sort.flat_map do |table|
      indexes = conn.indexes(table).select { |i| i.columns.is_a?(Array) }
      indexes.flat_map do |narrow|
        indexes.filter_map do |wide|
          next if wide.name == narrow.name
          next unless wide.where.nil?
          # STRICT, so two indexes on EXACTLY the same columns slip through — equally redundant,
          # and this guard says nothing about them. Zero such pairs exist today (checked at review),
          # so it is a recorded limit rather than a defect; widening it means deciding WHICH of an
          # identical pair to name, which a `>` comparison never has to.
          next unless wide.columns.length > narrow.columns.length
          next unless wide.columns.first(narrow.columns.length) == narrow.columns
          next if PREFIX_INDEX_EXEMPTIONS[table] == narrow.name

          "#{table}: #{narrow.name} #{narrow.columns.inspect} " \
            "is a strict prefix of #{wide.name} #{wide.columns.inspect}"
        end
      end
    end.uniq

    assert_empty pairs,
                 "PREFIX_PAIRS=#{pairs.size}\n  #{pairs.join("\n  ")}\n" \
                 "Each narrow index above is fully served by the wider one and only costs writes. " \
                 "Drop it in a migration. If it came from `t.references :user, foreign_key: true`, " \
                 "pass `index: false` there instead. If you believe one must STAY, it needs a " \
                 "measured query plan showing SQLite's appended-rowid seek is load-bearing for a " \
                 "real query — then add it to PREFIX_INDEX_EXEMPTIONS citing that measurement."
  end
end
