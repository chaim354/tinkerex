require "test_helper"
require "ripper"

# Executes the two "standing tripwire greps" that CLAUDE.md cites as PROOFS of the maker/file-layer
# boundary (§14a, §14c) and of the capability-gate design (§14a).
#
# WHY THIS FILE EXISTS. Until now both were prose. Nothing ran them, and one had already drifted
# undetected: it read "returns nothing" for months after the addon framework made the true answer
# "exactly one hit, and it is library_output.rb" — corrected only when a fresh reader happened to
# type the command. A proof nobody runs is a comment. Same pattern as ci_hygiene_test.rb and
# deploy_hygiene_test.rb: guard the facts no other test can see. (The count moved again since —
# Arc B Task 2 gave both chunk adapters a `#put_chunk` port verb, so as of this file's own next
# test the true answer is back to zero. Left as history rather than rewritten: it is what this
# paragraph is arguing FROM, not a claim about the file's current behaviour.)
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
  #
  # `minimum:` IS REQUIRED, AND THAT IS THE POINT — a guard that scans a directory dies silently
  # when the directory leaves (CLAUDE.md §14e). Both greps below end in `assert_empty`, which passes
  # perfectly and forever over ZERO files, so a glob that stops matching retires the invariant with
  # nothing going red. Measured before this assertion existed: repointing every glob in this file at
  # a nonexistent directory left it at an identical 6 runs / 14 assertions / 0 failures. A keyword
  # with no default makes forgetting it an ArgumentError rather than a silent omission, which is the
  # difference between a helper that offers non-vacuity and one that enforces it.
  #
  # It is a PLAUSIBILITY FLOOR, never today's count: pinning the exact number turns an ordinary
  # file being added or deleted red for a reason that has nothing to do with the rule.
  def offending(globs, pattern, minimum:)
    files = Array(globs).flat_map { |rel| Dir.glob(ROOT.join(rel, "**", "*.rb")) }.sort

    assert_operator files.size, :>=, minimum,
                    "#{Array(globs).join(', ')} matched #{files.size} file(s), below the " \
                    "plausibility floor of #{minimum} — so `assert_empty` below cannot fail for " \
                    "the reason it exists (CLAUDE.md §14e). A renamed or moved directory is the " \
                    "usual cause: fix the glob, and only then lower the floor"

    files.flat_map do |file|
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
  # discover"). ENGINE_MODELS ITSELF IS GONE AS OF STAGE 3b PHASE A TASK 3 -- see the note where it
  # used to be defined, below the method. The LESSON of this paragraph (a bare model reference is a
  # real boundary crossing) outlives the LIST that implemented it: Task 3 moved every one of these
  # models under `Sync::`, so the bare spelling this paragraph worried about no longer resolves to
  # anything at all, and the qualified spelling was already caught by the `Sync` check one line up.
  # AND WIDENED AGAIN, TO ASSOCIATION ACCESS -- because the constant check alone was WIDER, NOT
  # STRONGER, and a review proved it rather than suspecting it. `user.versions.find_by(...)` is the
  # more idiomatic Rails way to reach a related table and it emits NO :on_const token at all, so:
  #
  #   - the Task 1 guard would NOT have caught `Node#current_version` -- the exact
  #     host-model-queries-engine-table violation Task 2 exists to fix, in a file it was scanning
  #   - `app/services/sharing/links.rb:41` (`user.versions.find_by!`) is a LIVE hit it cannot see,
  #     one line above the `ManifestChunk` const at :60 that is the only reason that file is listed
  #
  # That matters beyond tidiness: Stage 3a Tasks 5 and 6 both lean on this guard reporting clean as
  # their proof the boundary holds. A guard that misses the idiomatic spelling would have let them
  # report success over an unenforced boundary -- §15's dominant recorded failure shape, arrived at
  # by building on a tool nobody had tried to evade.
  #
  # ENGINE_ASSOCIATIONS are the `has_many` names User declares for the seven moving models. Matched
  # as :on_ident (a method call) rather than :on_const. `devices` is absent because `Device` itself
  # never moves under `Sync::` -- it stays with the host (CLAUDE.md §14j), so `user.devices` is
  # ordinary host code reaching a host table, not an engine seam this file has any business timing.
  ENGINE_ASSOCIATIONS = %w[versions chunks manifest_chunks pending_commits changelog_entries
                           conflicts file_locks].freeze

  def sync_references(file)
    rel = Pathname.new(file).relative_path_from(ROOT)
    Ripper.lex(File.read(file)).filter_map do |(pos, type, str, _)|
      hit = case type
      # `Storage` sits beside `Sync` here because it is the OTHER namespace that left with the
      # engine (Storage::ChunkStore). It was named in the V1::BaseController test's TITLE while
      # this helper checked only `Sync`, so that test promised a coverage it did not provide --
      # and a `Storage::ChunkStore` reference in a controller is caught by no other guard: §14c's
      # chunk-internals scan covers `app/**/maker` only. Safe to flag: `ActiveStorage` lexes as a
      # SINGLE :on_const token, so it cannot collide, and app/ + lib/ hold zero bare `Storage`
      # const tokens today (checked with Ripper, not grep).
      when :on_const then str == "Sync" || str == "Storage"
      when :on_ident then ENGINE_ASSOCIATIONS.include?(str)
      end
      "#{rel}:#{pos.first}" if hit
    end
  end

  # ENGINE_MODELS IS GONE, DELETED RATHER THAN LEFT EMPTY -- the same "the list must die with its
  # last entry, not linger" rule SYNC_SEAM_EXCEPTIONS's own comment states further down (and its
  # accompanying test enforces mechanically; this one has no test to catch a forgotten `[]`, only
  # this comment, which is why the deletion happened in the same commit as the reason for it).
  #
  # IT USED TO NAME SIX OF THE SEVEN MOVING MODELS (Version, ManifestChunk, PendingCommit,
  # ChangelogEntry, Conflict, FileLock -- `Chunk` was always excluded; see below) so `sync_references`
  # could catch a maker-layer file reaching one of them by BARE constant, the way `Node.find(...)`
  # legitimately reaches a host table. STAGE 3b PHASE A TASK 3 moved all eight engine models under
  # `Sync::`, which means the bare spelling this list existed to catch NO LONGER RESOLVES TO
  # ANYTHING: a maker-layer `Version.find(...)` today raises `NameError` before this test would ever
  # run, because there is no top-level `Version` constant left for it to find. The only spelling that
  # still reaches these models -- `Sync::Version`, `Sync::ManifestChunk`, and so on -- already lexes
  # as the bare "Sync" token `sync_references`'s `:on_const` arm catches on its own, with nothing
  # extra needed after it. Keeping a name-by-name list around to catch a mistake Ruby itself now
  # refuses to let compile would be exactly the "list that no longer does anything" this task's own
  # instructions warned against leaving behind.
  #
  # THE THREE EXCLUSIONS THIS LIST USED TO CARRY EACH DESERVE A DIRECT ANSWER, NOT A SILENT DROP --
  # every one of them was an argument for leaving ONE NAME OFF THIS LIST specifically, and the list
  # itself is what is gone; the underlying facts are not, and are worth restating so a future reader
  # does not have to re-derive them from a stale reference to a constant that no longer exists:
  #
  #   - `Chunk` was excluded for a TOKENIZATION reason, not a policy one: `FileLayer::Chunk`
  #     (CLAUDE.md §14a's one sanctioned chunk-internals adapter) is a DIFFERENT class from the AR
  #     model, and a bare on_const "Chunk" could not be told apart from the tail of a fully-qualified
  #     `FileLayer::Chunk` reference by token shape alone (`FileLayer.build`'s own factory,
  #     app/services/file_layer.rb:120, writes `Chunk.new` *inside* `module FileLayer` on purpose,
  #     resolving to the adapter). That ambiguity is now STRUCTURALLY GONE, not merely still avoided:
  #     the real AR model is `Sync::Chunk` (app/models/sync/chunk.rb) as of Task 3, so a genuine
  #     reference now carries the same unambiguous "Sync" token every other engine model does, and
  #     `FileLayer::Chunk` never has and still does not carry one -- there is nothing left to confuse
  #     it with, so there is nothing left to exclude.
  #   - `Device` was excluded because it STAYS WITH THE HOST (CLAUDE.md §14j) and was never a model
  #     this list needed to name -- adding it would have flagged legitimate host code
  #     (application_controller.rb, library_output.rb) for using a model that is properly theirs.
  #     Still true, and needs no exclusion now for the identical reason `Chunk` doesn't: `Device` was
  #     never asked to become `Sync::Device` and carries no "Sync" token to catch, list or no list.
  #   - `ShareLink` was excluded because no maker-layer file reached for it by bare constant at the
  #     time (Stage 3a Task 6) -- it was a real engine model even then, just not yet a violation
  #     anywhere. Task 3 namespaced it the same way as its seven siblings: `Sync::ShareLink` is
  #     caught by the bare "Sync" check exactly like the rest, with no special-casing either way.

  test "the maker layer reaches for chunk internals nowhere at all" do
    # CLAUDE.md §14c. The maker layer must not know files are chunks — that is the whole point of
    # the FileLayer port. Addon-generated output USED TO BE the one legitimate exception: it has no
    # client to presign for, so in chunk mode the server itself drove a single-chunk Sync::Commit
    # plus a direct `Sync::Storage::ChunkStore#put`, mirroring what the web uploader does from the
    # browser. Arc B Task 2 closed it: `#put_chunk` is now a port verb both `FileLayer::Chunk` and
    # `FileLayer::ChunkRemote` implement, so `Maker::Addons::LibraryOutput` no longer reaches past
    # the port at all — the direct call was a `NameError` on any deployment that does not load the
    # sync engine, and `chunk_remote` is exactly that deployment.
    #
    # The assertion is "no hits, full stop" now. It used to be "one hit, and it is
    # library_output.rb" — asserting the bare count alone would have let the coupling migrate to
    # some other file while the test stayed green, which is why this still asserts the SET is
    # empty rather than merely that its size is 0 (a size-only assertion cannot name an offender).
    # The directory set is DERIVED FROM THE TREE — `app/**/maker` is every maker directory there
    # is — so a NEW `app/<x>/maker/` is covered the day it is created. It was a remembered list
    # of three and silently missed `app/controllers/v1/maker` + `app/models/concerns/maker` (15
    # files), where a ChunkStore call left this test GREEN over a live §14a breach — in the very
    # file §14a introduced to replace a remembered grep. Derive, don't enumerate: the same rule as
    # stimulus_hygiene_test.rb's registered_identifiers.
    #
    # THE FLOOR IS 50 AGAINST 91 FILES IN 7 DIRECTORIES TODAY. It exists because this glob is
    # DERIVED FROM A NAMING CONVENTION and CLAUDE.md:4 invites the rename that would empty it —
    # "Working name: **Maker Server** (rename freely)". Rename `maker` and `app/**/maker` matches
    # nothing, `hits` is `[]`, and this test goes on passing over a maker layer it can no longer
    # see. That is the one realistic way this guard dies, and it dies green.
    hits = offending(%w[app/**/maker], /manifest_chunks|ChunkStore/, minimum: 50)

    assert_empty hits,
                 "expected ZERO chunk-internals references in the maker layer, got #{hits.size}:\n" \
                 "  #{hits.join("\n  ")}\n" \
                 "A hit means the maker/file-layer split (CLAUDE.md §14a) has been breached — route " \
                 "the write through FileLayer#write, #put_chunk or #begin_upload/#finalize_upload " \
                 "instead. If a new direct reference is genuinely unavoidable, update this test and " \
                 "CLAUDE.md §14c together, deliberately — do not let this test go red silently past " \
                 "that."
  end

  # THE CURRENT PROJECT IS RETIRED (structural redesign spec §9.1, slice 4) AND NOTHING MAY READ A
  # DESTINATION FROM SESSION OR USER STATE AGAIN (spec §10). New files land in the folder the maker
  # is looking at — FolderDestination, set by the action that renders that folder — and a destination
  # read from a session key or a user column is the design this replaced: it needed three rounds of
  # fixes because the place a file landed was not the place the maker was looking.
  #
  # Ripper over app/ + lib/ + config/routes.rb, and over every ERB template COMPILED to Ruby first
  # (Erubi drops `<%# %>` comments, so prose about the old design never trips it). Tokens, not text:
  # `:on_ident` catches a method, a local and a `session[:current_project_id]` key; `:on_const` the
  # concern and controller; `:on_tstring_content` a string that IS one of the names, which is how
  # `session["current_project_id"]` spells the key (review of slice 4). Only a WHOLE string token
  # matches, so prose that merely mentions a name inside a longer string never does. The columns
  # themselves are DROPPED (slice 7's migration), so a read fails at the database; this catches the
  # NAMES, which is where a revival starts.
  RETIRED_DESTINATION_NAMES = %w[
    current_project current_project_id current_project_folder_node_id current_project_choices
    current_project_notice remember_current_project remember_current_project? make_current
    attach_addon_files_to_current_project CurrentProject CurrentProjectController
  ].freeze

  test "nothing reads a destination from session or user state: the current project's names are gone" do
    rb = Dir[ROOT.join("app/**/*.rb"), ROOT.join("lib/**/*.rb"), ROOT.join("config/routes.rb")]
    erb = Dir[ROOT.join("app/views/**/*.erb")]
    refute_empty rb, "the Ruby scan found no files — the guard would pass over nothing"
    refute_empty erb, "the template scan found no files — the guard would pass over nothing"

    hits = (rb.map { |f| [ f, File.read(f) ] } +
            erb.map { |f| [ f, ActionView::Template::Handlers::ERB::Erubi.new(File.read(f)).src ] })
      .flat_map do |file, source|
        rel = Pathname.new(file).relative_path_from(ROOT)
        Ripper.lex(source).filter_map do |(pos, type, str, _)|
          next unless %i[on_ident on_const on_tstring_content].include?(type) && RETIRED_DESTINATION_NAMES.include?(str)

          "#{rel}:#{pos.first} #{str}"
        end
      end
    assert_empty hits, "the retired current project is referenced again"
  end

  # NO ADAPTER CLASS-CHECKS IN THE GIT SURFACE. `is_a?(FileLayer::Share)` and `local_worktree?`
  # give the SAME answer on all three backends today — share true, s3 and chunk_remote false — so
  # swapping one for the other changes no behaviour anywhere and NO behavioural test can go red for
  # it. This is the only instrument that can see it. Same shape as the Sync:: seam guard below, and
  # the same argument §14b makes about Library::ScanJob: that gate WAS `is_a?(FileLayer::Share)`,
  # it answered false for S3, and the library was silently never indexed. Widening commits to
  # another backend must be a new ANSWER in Capabilities, never a rewrite of the callers.
  #
  # SCOPED TO app/, DELIBERATELY. test/services/file_layer/adapter_contract.rb asserts WHICH
  # adapter answers `local_worktree?` true and needs the class name to say it; a test naming the
  # live adapter is the opposite of production code branching on one, so scanning test/ here would
  # forbid the assertion that pins the capability's whole meaning.
  #
  # COMMENT LINES ARE SKIPPED, the same load-bearing choice `offending` documents above and for the
  # identical reason: this repo writes the forbidden spelling INTO comments in order to forbid it
  # (app/services/file_layer/capabilities.rb says "NEVER SPELL THIS `is_a?(FileLayer::Share)`" in
  # as many words), so a whole-file `File.read.match?` would eventually go red for a paragraph
  # explaining the rule. Scanned line by line here rather than through `offending` because that
  # helper takes DIRECTORY globs and one of the three arms is a single file — pointing it at
  # `app/services/library` instead would sweep the scanner, the reconciler and the trash purge into
  # a rule nobody has argued for them.
  #
  # NON-VACUITY IS ASSERTED PER ARM, NOT ON THE TOTAL (§14e), and the arms are 2 / 53 / 1 files
  # today. A single `refute_empty` over the union cannot fail: `app/controllers` alone keeps it
  # green, so moving or renaming `app/services/maker/git/` — the realistic way this guard dies,
  # since that directory is the youngest thing it watches — would retire the invariant with
  # nothing going red. That is the exact degradation the Sync:: guard below spells out for its own
  # three arms.
  def test_the_git_surface_never_branches_on_an_adapter_class
    git_files  = Dir.glob(ROOT.join("app", "services", "maker", "git", "**", "*.rb"))
    ctrl_files = Dir.glob(ROOT.join("app", "controllers", "**", "*.rb"))
    tree_files = Dir.glob(ROOT.join("app", "services", "library", "working_tree.rb"))

    refute_empty git_files,  "app/services/maker/git/**/*.rb matched nothing — this scan is vacuous (CLAUDE.md §14e)"
    refute_empty ctrl_files, "app/controllers/**/*.rb matched nothing — this scan is vacuous (CLAUDE.md §14e)"
    refute_empty tree_files, "app/services/library/working_tree.rb matched nothing — this scan is vacuous (CLAUDE.md §14e)"

    offenders = (git_files + ctrl_files + tree_files).sort.flat_map do |file|
      File.readlines(file, chomp: true).each_with_index.filter_map do |line, idx|
        next if line.lstrip.start_with?("#")
        next unless line.match?(/is_a\?\(\s*FileLayer::/)
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}"
      end
    end

    assert_empty offenders,
                 "the git surface must ask a capability, never an adapter class — got:\n" \
                 "  #{offenders.join("\n  ")}\n" \
                 "`local_worktree?` and `is_a?(FileLayer::Share)` agree on all three backends " \
                 "today, so nothing else in the suite can tell you this happened (CLAUDE.md §14b: " \
                 "the ScanJob class check answered false for S3 and silently never indexed the " \
                 "library)."
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
  # `app/models/sync/**/*.rb` COVERS ALL EIGHT MOVING MODELS' OWN DEFINITION FILES WITH ONE GLOB,
  # AS OF STAGE 3b PHASE A TASK 3 -- SUPERSEDING SIX INDIVIDUAL ENTRIES (ADDED IN STAGE 3a TASK 1)
  # PLUS `share_link.rb`'s OWN LATER ONE (Task 6). Each of the eight opens with `class Sync::<Name>
  # < ::ApplicationRecord`, naming itself, and self-declaration is not the maker layer "reaching
  # into" the engine -- it IS the engine, exactly as `app/services/sync/**` is above. A DIRECTORY
  # GLOB is now the right shape where six-plus-one individual file entries used to be required: Task
  # 1's individual listing existed only because `app/models/` is SHARED with every maker model, so a
  # wholesale `app/models/**` glob would have exempted the maker layer's own models too -- naming
  # each engine model file was the only way to claim exactly the right eight-minus-Chunk (see below)
  # without over-claiming. Task 3 moved all eight into their OWN subdirectory, `app/models/sync/`,
  # which holds nothing else and is never going to (it is the engine's own model namespace, the same
  # shape `app/services/sync/` and `app/services/storage/` already are above) -- so a glob here
  # exempts nothing it shouldn't, the identical argument the sharing/ glob below already makes.
  # `version.rb`'s own internal `Sync::ManifestChunk.where(...)` reference (`:16`, fully qualified
  # since Task 3 -- see that file's own comment for why the compact `class Sync::Version` form
  # requires it, unlike a `module Sync; class Version; end; end` nesting) is covered by this same
  # glob for the same reason: it is engine code referencing engine code, not a second file to name.
  # `Chunk`'s own model file (app/models/sync/chunk.rb) is covered by this glob TOO now, though it
  # never needed an entry before Task 3: bare `Chunk` was deliberately excluded from the old
  # ENGINE_MODELS list (a tokenization problem, not a policy one -- see the note above where that
  # list used to live), so nothing in this file ever matched it regardless of which bucket its file
  # sat in. `Sync::Chunk` carries the same "Sync" token every other engine model does, so as of Task
  # 3 it DOES need to be engine-side for the guard to agree with itself -- and now it is, for free,
  # by sitting in the same directory as its seven siblings.
  #
  # STAGE 3a TASK 6 ADDS `app/services/sharing/**` AND `app/models/share_link.rb`, and a reader
  # skimming this list needs the argument stated, not assumed -- "sharing a file with someone"
  # reads exactly like a maker-layer feature (the way collections or tags are), and both files sit
  # in directories that look maker-shaped rather than under `app/services/sync/`. It is not a
  # maker feature. Three independent facts say so (Stage 3 boundary design §1, re-confirmed live
  # against this tree before anything moved):
  #
  #   - Share links CANNOT EXIST on share or s3 at all. V1::ShareLinksController gates #create on
  #     `require_capability! :versioned`, and Sharing::Links.create_for_version! resolves its
  #     target via `user.versions.find_by!(...)` -- a real `versions` ROW is structurally required
  #     to mint one, and `versioned` is true on chunk, false on the other two (CLAUDE.md §14a). The
  #     feature is chunk-only by construction, not by convention that could drift.
  #   - `share_links.version_id`/`.manifest_id` reference two tables that are ALREADY sync-side
  #     here (`versions`, `manifest_chunks`), and `Sharing::Links.redeem` queries `ManifestChunk`
  #     directly and presigns through `Sync::Storage::ChunkStore` -- the engine's own chunk data plane.
  #   - `lib/schema_map.rb` already filed `share_links` under "Sync control plane" (grouped with
  #     `changelog_entries`/`pending_commits`/`conflicts`/`file_locks`), and that map is TESTED
  #     (`bin/rails schema:map:check`) -- someone reached this conclusion independently, in an
  #     artifact this repo already enforces, before this task existed.
  #
  # Why it matters beyond taxonomy: `Sync::Gc.apply_retention!` reads `share_links`
  # (`referenced_version_ids`, app/services/sync/gc.rb) to protect the version a live share link
  # points at from nightly pruning. Split the feature from the engine and a future refactor can
  # sever that read with no build break and no red test -- retention would silently destroy the
  # bytes behind a URL a user already sent someone. Filing the feature as sync-side here makes
  # that coupling engine-INTERNAL, closing the hazard by construction; see
  # test/services/sync/gc_test.rb's "tiered retention keeps a version referenced by a live share
  # link" for the guard that pins it (mutation-checked: deleting gc.rb's `user.share_links` line
  # turns that test red).
  #
  # A DIRECTORY GLOB for `sharing/`, not an individual file -- `app/services/sharing/` holds
  # nothing else and is never going to hold a maker-layer file (it is the share-link feature's own
  # service namespace), so a glob here exempts nothing it shouldn't the way a bare `app/models/**`
  # would. `docs/plan-sharing.md`'s future Spaces work (full read/write sharing) lands in this same
  # namespace, sync-side, with no second entry needed. `share_link.rb` got an INDIVIDUAL entry here
  # at the time, for the same reason the six other AR models above did: `app/models/` is shared
  # with every maker model, so only specific files could be named there, never the directory
  # itself. STAGE 3b PHASE A TASK 3 SUPERSEDES THAT: `share_link.rb` moved to `app/models/sync/`
  # alongside its seven siblings and is now covered by the `app/models/sync/**/*.rb` glob above,
  # same as the rest -- no individual entry for it remains here.
  #
  # The two v1 controllers (ShareController, ShareLinksController) need NO new entry:
  # `app/controllers/v1/**/*.rb`, below, already covers them.
  #
  # STAGE 3b PHASE A TASK 1 ADDS `app/services/storage/**` -- FOUR FILES (`chunk_store.rb`,
  # `local_chunk_store.rb`, `memory_chunk_store.rb`, `s3_chunk_store.rb`, 414 lines) DEFINING
  # `Storage::ChunkStore` AND ITS THREE CONCRETE STORES, ENGINE BY EVERY FUNCTIONAL MEASURE AND
  # UNTIL NOW IN NEITHER BUCKET -- worse than a missing inventory entry, because
  # `engine_side_files` (below) is what BOTH directions consult: the reverse test (further down)
  # scans it directly for `Maker::` references, and the forward test SUBTRACTS it to get
  # `maker_layer_files`. A file in neither bucket is invisible to both AT ONCE -- a `Maker::`
  # reference planted inside `Storage::S3ChunkStore` would have passed EITHER test, not merely
  # gone unwatched by one of them (mutation-checked below: GREEN before this entry existed).
  #
  # Checked before adding it, not assumed: every real (non-comment, non-string) call to
  # `Storage::ChunkStore.current` in the tree already resolves to a file this list covers --
  # `app/services/sync/**`, `app/services/sharing/**`, `app/services/file_layer/chunk.rb`, and the
  # fourteen-controller-wide `app/controllers/v1/**` all reach it from files already sync-side.
  # Three callers sit outside that coverage and this task leaves them there, because none is a new
  # problem: `Maker::Addons::LibraryOutput#write` is CLAUDE.md §14c's ONE sanctioned direct call in
  # the maker layer (pinned by the chunk-internals test at the top of this file, not by this
  # list); `DevBlobsController` is a DEV/TEST-ONLY stand-in for object storage itself (its own
  # header says so -- it presigns to itself because there is no off-box store to presign to
  # locally, and it is not under `app/controllers/v1/` at all); and `V1::StashRequestBaseUrl`
  # (`app/controllers/concerns/v1/stash_request_base_url.rb`) sits under
  # `app/controllers/concerns/`, a sibling of `v1/` the blanket glob does not reach, and is Stage
  # 3a Task 5's own documented seam. None of the three would be caught by widening this list
  # anyway -- `sync_references` matches a bare `Sync` constant, never a bare `Storage` constant
  # (at Task 1 time, only the dedicated `V1::BaseController` test below checked for that
  # separately; Task 4's rename made it redundant there too -- see the note above that test) -- so
  # they are recorded here only because "verify every caller is sync-side" is the argument FOR
  # this entry, and naming the exceptions is what makes that argument checkable rather than
  # asserted.
  #
  # STAGE 3b PHASE A TASK 2 ADDS TWO `lib/` FILES, AND WIDENS BOTH SCANS TO `lib/` AT ALL -- until
  # now every `Dir.glob` in this test rooted at `app/**`, so `lib/` was unwatched in EITHER
  # direction regardless of content. `lib/tasks/chunks.rake` calls `Sync::ChunkReaper.reap!`/
  # `.reap_all!` and `Sync::PendingCommitReaper.reap!`/`.reap_all!` -- real code, not the
  # `puts "Sync::ChunkReaper ..."` status lines beside them, which are strings and lex as
  # `:on_tstring_content` regardless of what they say. `lib/postgres_pooler_check.rb` calls
  # `Sync.engine_present?`, a real singleton-method call on the bare `Sync` module -- exactly the
  # shape `sync_references`'s own comment above already warns is easy to miss, since it emits
  # `:on_const` + `:on_period`, not `:on_const` + `:on_op "::"` (verified: `Sync.engine_present?`
  # lexes identically to the `Sync.load_manifests` trap that motivated dropping the `::`-adjacency
  # requirement in the first place). Both are named individually rather than a `lib/**` glob, for
  # the same reason the eight model files were before they got their own subdirectory (above):
  # `lib/` holds plenty that is NOT engine-side (next paragraph), so a directory-wide entry would
  # claim files it has no business claiming. Unlike the models, these two have no dedicated `lib/`
  # subdirectory of their own to move into, so they stay named individually rather than globbed.
  #
  # `lib/schema_map.rb` -- ~372 lines describing BOTH sides' tables (`LAYOUT`, `EDGES`) -- is
  # DELIBERATELY NOT added here, even though it is the strongest-looking candidate in `lib/`
  # besides the two above. It genuinely belongs to neither side (Stage 3b Task 8 leaves it with
  # the host, describing tables whose migrations will live in another repo once the engine ships),
  # and the honest way to say that is to let the widened scan below SEE it and confirm it has
  # nothing to flag, not to keep it unwatched. Checked, not assumed: every table/column name it
  # names -- `versions`, `chunks`, `manifest_chunks`, `pending_commits`, `changelog_entries`,
  # `conflicts`, `file_locks` -- appears as DATA, inside `%w[]` word-array literals and quoted
  # `[from, to, kind, label]` edge tuples, which Ripper lexes as `:on_tstring_content`, never
  # `:on_const`/`:on_ident` (verified directly against this file's own lexer output, the same
  # instrument `sync_references` uses -- not inferred from reading the source). So it triggers no
  # hit once scanned, and needs no `SYNC_SEAM_EXCEPTIONS` entry either: that list is for a file the
  # scan DOES flag, pending scoped, future work (Task 6's shape) -- an entry for a file that trips
  # no violation would itself fail the "stale entry" assertion two tests below, immediately.
  #
  # The rest of `lib/` sweeps into the widened maker-layer scan clean, checked the same way, not
  # left to assumption. `lib/tasks/previews.rake`, `projects.rake` and `lbrn.rake` are real
  # maker-layer code (`Maker::Previews::MissingBackfill`, `Maker::ProjectIntake`,
  # `Maker::Previews::LbrnGeometry`) and belong in `maker_layer_files` exactly like any other maker
  # service -- catchable the moment one of them reaches for `Sync::` or a bare engine model, which
  # is the whole point of widening the scan to see them at all. `lib/tasks/schema_map.rake` and
  # `lib/library_backend_check.rb` contain no real hits either. The latter in particular READS
  # engine-shaped -- it is `PostgresPoolerCheck`'s twin in argument, "refuse to boot a deployment
  # whose backend is misconfigured" -- but IS host code: it guards the `share`/`s3` FILE LAYER, not
  # the chunk engine, and its one real cross-reference is to `Library::Scanner::TEMP_PREFIX`, a
  # maker-layer constant.
  #
  # STAGE 3b PHASE A TASK 4 REMOVES THE `app/services/storage/**` ENTRY RATHER THAN REPOINTING IT --
  # the four files it named (`chunk_store.rb` and its three concrete stores) moved to
  # `app/services/sync/storage/`, becoming `Sync::Storage::ChunkStore` and friends, so they are now
  # covered -- for free -- by the `app/services/sync/**/*.rb` glob two lines up. Repointing this
  # entry to `app/services/sync/storage/**/*.rb` would match the identical file set a second time;
  # leaving it in place, unrepointed, would match NOTHING (the directory no longer exists) and be
  # exactly the "list that no longer does anything" §15 warns against leaving behind. Either way the
  # entry earns its keep only by being deleted. Checked, not assumed: `Dir.glob` against the old path
  # returns `[]` post-move, confirmed before removing the line.
  #
  # AND NARROWS `app/channels/**/*.rb` TO `app/channels/sync/**/*.rb`, A FIX RATHER THAN A RENAME --
  # `library_channel.rb` moving into its own `sync/` subdirectory (same shape as the model files
  # under `app/models/sync/`, Task 3) is the first point since this glob was written that a narrower
  # spelling has been POSSIBLE. Before this move, `app/channels/**/*.rb` swept in
  # `app/channels/application_cable/{channel,connection}.rb` alongside the one file that actually
  # belongs on this list -- host boilerplate misclassified as engine-side (CLAUDE.md §14j:
  # `ApplicationCable::Connection#connect` calls `Device.authenticate`, and `Device` stays host). It
  # never produced a wrong test RESULT (`ApplicationCable::*` references no `Maker::` and no
  # `Sync::`/engine association, so both directions of the guard stayed silent about it either way),
  # but it was still the wrong classification sitting unnoticed in a glob nobody had reason to
  # revisit until the file it was really for got its own directory. `app/channels/sync/` holds
  # nothing else and is never going to (the engine's own channel namespace, identical argument to
  # `app/models/sync/**/*.rb` and `app/services/sharing/**/*.rb` above) -- so the narrower glob
  # exempts nothing it shouldn't, and `app/channels/application_cable/**` now correctly falls into
  # `maker_layer_files` (in the "reaches the sync engine" test below) and out of `engine_side_files`
  # (in the "reaches into Maker::" test above), where a host file belongs on both counts. Confirmed
  # empirically, not merely argued: re-running with the narrower glob adds exactly the two
  # `application_cable/*.rb` files to `maker_layer_files` and produces zero new hits from either --
  # neither references `Sync::` or a bare engine association, so the narrowing is free.
  # SINCE 2026-08-26 THAT LAST CLAUSE IS HISTORY: `app/channels/` is gone entirely (S09-1 -- no
  # channel, no subscriber, and the device-token Connection had neither a caller nor a credential
  # it could hold). Kept because the ARGUMENT for narrowing a glob rather than renaming it is the
  # reusable part; `test/cable_absent_test.rb` is what keeps the directory from coming back.
  #
  # STAGE 3b PHASE A CLOSE-OUT. A close-out review found FIVE MORE bare top-level engine constants
  # Tasks 3 and 4 missed -- `RetentionJob`, `ChunkReaperJob`, `PendingCommitReaperJob`,
  # `Sharing`(::Links), and `PostgresPoolerCheck` -- which is why Task 4's own paragraph above
  # ("the last two top-level names the engine squatted") and its STATUS.md echo were both false.
  # All five are unambiguously engine-side by this guard's own inventory before this task touched
  # anything: the three job files (individually, since `cef39db` -- long before Stage 3a/3b, back
  # when this guard was first built) and `lib/postgres_pooler_check.rb` (individually, Task 2) were
  # ALREADY named in SYNC_SIDE_GLOBS below, and `app/services/sharing/**` was already here too
  # (Stage 3a Task 6). Being ON this list was never what namespaced them -- this list says "treat
  # this file as engine code no matter what it's named", not "this file is named `Sync::`something"
  # -- so all five went on squatting bare top-level names the whole time Tasks 3/4 believed the job
  # was finished, invisible to `sync_references` by construction (it only fires on a real `Sync`
  # token, and none of the five carried one). CLAUDE.md §14j is the invariant.
  #
  # Three glob-collapsing changes, each the identical move Task 3 made for the eight models and
  # Task 4 made for `Storage`:
  #
  #   - The three job files move into their own `app/jobs/sync/` subdirectory (mirroring
  #     `app/jobs/library/` and `app/jobs/maker/`, the host's own per-namespace job directories),
  #     so the three individual `app/jobs/*_job.rb` entries below collapse into one
  #     `app/jobs/sync/**/*.rb` glob -- the directory holds only these three files and is never
  #     going to hold a fourth thing that isn't engine-side, the same argument `app/models/sync/`
  #     and `app/channels/sync/` already make.
  #   - `lib/postgres_pooler_check.rb` moves into a new `lib/sync/` subdirectory, becoming
  #     `lib/sync/**/*.rb`. This FLIPS the STAGE 3b PHASE A TASK 2 reasoning above rather than
  #     contradicting it: that paragraph named individually rather than globbed as the answer
  #     specifically because "these two have no dedicated `lib/` subdirectory of their own to move
  #     into" -- true then, false now that one of the two has exactly that subdirectory.
  #     `lib/tasks/chunks.rake` still has no such subdirectory (it is one file among many under
  #     `lib/tasks/`, most of which is NOT engine-side -- Task 2's own paragraph), so it alone stays
  #     individually named.
  #   - `app/services/sharing/**/*.rb` is REMOVED rather than repointed -- `Sharing::Links` becomes
  #     `Sync::Sharing::Links` at `app/services/sync/sharing/links.rb`, so it is now covered for
  #     free by the `app/services/sync/**/*.rb` glob two lines up, the identical shape Task 4 used
  #     to retire `app/services/storage/**` when `Storage` moved under `app/services/sync/storage/`.
  #     Checked, not assumed: `Dir.glob("app/services/sharing/**/*.rb")` returns `[]` post-move.
  #
  # Every real reference to the five renamed constants was found with Ripper (not grep), scoped to
  # `{app,test,lib,config,db}/**/*.rb` plus a manual sweep of `.rake`/`.yml`/`.erb` files (`Sharing`
  # is common English, so every hit was read in context rather than replaced blind -- the same
  # substring trap the a50f0bf commit message records for `test/models/share_link_test.rb`'s test
  # class briefly picking up a `Sync::` prefix it shouldn't have, from a plain string replace on
  # "ShareLink" catching the "ShareLink" inside "ShareLinkTest"). Two test classes here needed the
  # opposite judgment calls, not the same one: `test/services/sharing/links_test.rb`'s
  # `Sharing::LinksTest` was ALREADY compact-namespaced (unlike `ShareLinkTest`'s flat name), so
  # extending it to `Sync::Sharing::LinksTest` is the parallel, correct move rather than that same
  # substring accident; `test/lib/postgres_pooler_check_test.rb`'s flat `PostgresPoolerCheckTest`
  # stayed flat, for the identical reason `ShareLinkTest` did.
  # `config/recurring.yml`'s three `class:` values (`RetentionJob`, `ChunkReaperJob`,
  # `PendingCommitReaperJob`) were requalified too -- `test/recurring_schedule_test.rb` resolves
  # them with `safe_constantize`, so a stale bare name there would have failed loudly, not silently.
  SYNC_SIDE_GLOBS = %w[
    app/services/sync/**/*.rb
    app/services/sync.rb
    app/controllers/v1/**/*.rb
    app/jobs/sync/**/*.rb
    app/channels/sync/**/*.rb
    app/services/file_layer/chunk.rb
    app/models/sync/**/*.rb
    lib/sync/**/*.rb
    lib/tasks/chunks.rake
  ].freeze

  # ONE FILE LEFT, NOT TWO -- app/services/sharing/links.rb is GONE from this list, not merely
  # forgiven. It used to be here because app/services/sharing/links.rb:60's
  # `ManifestChunk.where(...)` (Sharing::Links, the share-link redemption path) was a real,
  # uncorrected cross-boundary reference (Stage 3a plan premises; boundary design §1). Stage 3a
  # Task 6 moved share_links -- model, service, and its two v1 controllers -- into SYNC_SIDE_GLOBS
  # above, so links.rb and share_link.rb are sync-side BY CONSTRUCTION now: `maker_layer_files`
  # excludes them before `sync_references` ever runs, and there is nothing left here to except.
  #
  # user.rb IS HERE FOR A DIFFERENT REASON THAN links.rb WAS, and conflating them would lose the
  # point. links.rb was maker-layer code REACHING INTO the engine -- fixed by moving the file.
  # user.rb is the DECLARATION SITE: User carries `has_many :versions`, `:chunks`,
  # `:manifest_chunks`, `:pending_commits`, `:changelog_entries`, `:conflicts`, `:file_locks` --
  # seven associations to models that move, on a host model that does not. (`has_many
  # :share_links` sits right beside those seven, uncommented -- it is NOT why user.rb is listed
  # here: `share_links` was deliberately left out of ENGINE_ASSOCIATIONS above, so that line emits
  # no hit on its own, and the seven original associations are sufficient by themselves to keep
  # user.rb on this list.) The seven-association straddle is the one the boundary design names
  # (`users` carries engine state, `head_seq` being the other half), and it is 3b's job, not 3a's,
  # to relocate those declarations: doing it now means a change this repo would immediately have
  # to redo once the engine owns them.
  #
  # It appears here only because the guard learned to see association access. Before that widening
  # it was invisible -- which is precisely the argument for the widening: the single largest
  # concentration of host->engine coupling in the app was sitting unflagged in the guard's own
  # scan set.
  #
  # THE LIST MUST DIE WITH ITS LAST ENTRY, NOT LINGER EMPTY -- see the test below for how. It does
  # NOT die with Task 6: user.rb survives into 3b, which is why this constant is amended rather
  # than deleted here.
  #
  # STAGE 3b PHASE A TASK 4 ADDS FOUR MORE, AND EVERY ONE IS A THIRD KIND OF ENTRY, DIFFERENT FROM
  # BOTH user.rb's AND THE OLD links.rb's. user.rb is a declaration site pending 3b relocation;
  # links.rb was maker code reaching into the engine, fixed by MOVING THE FILE. These four are
  # PERMANENT, ALREADY-SANCTIONED touch points that this guard simply could not see before Task 4,
  # for the same reason the old `Storage` needed its own dedicated Ripper pass in the
  # V1::BaseController test below rather than folding into `sync_references`: `sync_references`
  # has only ever matched the literal token "Sync", and every one of these four called
  # `Storage::something` or bare `LibraryChannel` -- names that shared NO token with "Sync" at all.
  # Task 4 prefixed both with `Sync::`, which is the whole point of the task, and the unavoidable
  # side effect is that a reference this guard was structurally blind to is now, correctly, visible
  # to it. Found empirically, not predicted: `bin/rails test test/architecture_invariants_test.rb`
  # after the rename, not a re-reading of this file.
  #
  #   - `app/controllers/concerns/v1/stash_request_base_url.rb` -- Stage 3a Task 5's own documented
  #     seam (see the STAGE 3b PHASE A TASK 1 paragraph above SYNC_SIDE_GLOBS): a controller CONCERN
  #     under `app/controllers/concerns/v1/`, a sibling of `v1/` no glob here reaches, that stashes
  #     the request's base URL for `Sync::Storage::LocalChunkStore`'s presigned blob URLs. Real,
  #     narrow, and permanent -- the concern's whole reason to exist is touching this one thing.
  #   - `app/controllers/dev_blobs_controller.rb` -- a DEV/TEST-ONLY stand-in for object storage
  #     itself, not under `app/controllers/v1/` at all, so no v1 glob was ever going to reach it
  #     either. It presigns to itself because there is no off-box store to presign to locally.
  #   - `app/services/maker/addons/library_output.rb` NO LONGER APPEARS HERE, as of Arc B Task 2 --
  #     it used to be listed for CLAUDE.md §14c's ONE sanctioned maker-layer chunk-internals
  #     reference (a direct `Sync::Storage::ChunkStore#put` call), named by the chunk-internals
  #     test at the top of this file. `#put_chunk` is now a port verb both `FileLayer::Chunk` and
  #     `FileLayer::ChunkRemote` implement, so that file names no bare `Sync` token at all any
  #     more -- keeping it on this list once it stopped violating anything would itself fail the
  #     "stale entry" assertion two tests below, immediately.
  #   - `app/services/maker/project_intake.rb` -- the deliberate host-calls-engine public API,
  #     `Sync::LibraryChannel.batch` (Stage 3a Task 4 Step 5; the class comment on
  #     app/channels/sync/library_channel.rb spells out why it must stay callable and public).
  #     THIS ONE IS NEW WITH TASK 4 SPECIFICALLY, not merely newly visible: before the rename the
  #     call was to bare `LibraryChannel`, a token `sync_references` never matched either.
  #
  # None of the four is "relocation work in progress" -- there is nowhere for any of them to move
  # to that would remove the reference, unlike links.rb. They stay on this list for as long as
  # `Storage`/`LibraryChannel` live under `Sync::` at all, which after Task 4 is permanently (short
  # of the whole engine actually extracting in Phase B, at which point the question of what counts
  # as "the maker layer" changes shape entirely).
  # base_controller.rb IS THE NEWEST ENTRY AND THE MOST DELIBERATE ONE. Phase B made the host's
  # V1::BaseController a one-line subclass of the engine's Sync::V1::BaseController, so that all
  # fourteen v1/maker/* controllers keep inheriting the same shared v1 infrastructure they always
  # did while the engine's own twelve controllers get a base they can carry into a standalone
  # mount. The direction is deliberate: the ENGINE ships the base and the HOST inherits it, never
  # the reverse -- an engine inheriting from a host class cannot load without that specific app,
  # which defeats the point of shipping it.
  #
  # This appearing here is the repointed guard EARNING ITS KEEP on its first run: it is a real new
  # host->engine dependency that Phase B introduced, and it was invisible for as long as the file
  # set still pointed at app/ and lib/.

  # THE OTHER DIRECTION, WHICH NOTHING GUARDED UNTIL STAGE 3a TASK 4 CLOSED THE LAST ONE. Every
  # guard in this file until now asked "does maker code reach into the engine?". The reverse --
  # the engine reaching into the HOST'S FEATURES -- is a different and arguably worse coupling:
  # not shared data the engine legitimately needs, but business logic that must EXIST for the
  # engine to run. An engine requiring a preview pipeline cannot be run standalone, which is goal
  # one of the whole separation.
  #
  # It was real, not hypothetical: V1::CommitsController#finalize called Maker::Previews::Enqueue
  # and Maker::ProjectIntakeJob directly, defended by a comment arguing it was the least-bad layer
  # to put them in. Task 4 dissolved that dilemma with Sync::Hooks -- the engine publishes, the
  # host subscribes -- and the count is now ZERO, which is why this asserts zero with no exception
  # list. It could not have been written before, and it is cheapest to add at the exact moment the
  # number reaches zero rather than after the next one is added back.
  #
  # v1/maker/** IS EXCLUDED and that is not a loophole: those fourteen controllers ARE the maker
  # API. They live under app/controllers/v1/ for routing reasons only, which is the same thing that
  # makes the "twelve controllers move" figure meaningless (boundary design §7).
  # ONE DEFINITION OF "ENGINE-SIDE", CONSULTED BY BOTH DIRECTIONS -- and it is a fix, not a tidy-up.
  # The two guards used to compute this separately: the forward one from SYNC_SIDE_GLOBS, the reverse
  # one from a hand-written list inlined in its own body. A final review proved both halves of what
  # that costs, by planting live violations and watching the suite stay green:
  #
  #   - the reverse list was STALE. Task 6 moved app/services/sharing/** to the engine side by adding
  #     it to SYNC_SIDE_GLOBS, and the reverse list -- three commits later, in the same file -- never
  #     learned about it. A `Maker::Previews::Enqueue` call planted in sharing/links.rb passed.
  #   - the forward scan EXEMPTED THE 14 v1/maker/* CONTROLLERS, because SYNC_SIDE_GLOBS carries a
  #     blanket `app/controllers/v1/**/*.rb`. `Version.count` planted in a maker controller passed.
  #     Those fourteen files ARE the maker API -- they live under v1/ for routing reasons only -- and
  #     the reverse guard already said exactly that, in a comment, while the forward one disagreed.
  #     Two tests in one file, disagreeing about which side of the boundary the same files sit on.
  #
  # So: one method, and the v1/maker/** carve-out stated ONCE. Everything Stage 3a claims -- that the
  # dependency count is zero and 3b's extraction is therefore mechanical -- rests on these two scans
  # covering what they say they cover.
  #
  # STAGE 3b PHASE A TASK 1 ADDS A SECOND CARVE-OUT, SAME SHAPE, FOR THE SAME REASON: the blanket
  # `app/controllers/v1/**/*.rb` glob in SYNC_SIDE_GLOBS sweeps in two files that are HOST, not
  # engine, exactly the way it swept in the fourteen v1/maker/* controllers before the rejection
  # above existed. Living under `v1/` is a routing fact, not a boundary one (boundary design §7),
  # and both of these already say so in their own comments -- quoted, not paraphrased, so a reader
  # does not have to trust this test's characterization of them:
  #
  #   - `devices_controller.rb`: "A Device is not only a sync participant: its token is the ONLY
  #     credential the whole v1 API accepts (see Authentication), including /v1/maker/*." An
  #     engine that owned this file would leave the maker API unable to authenticate a single
  #     request without the engine mounted -- the identical argument CLAUDE.md §14j already makes
  #     for why the `Device` MODEL stays host, never namespaced under `Sync::` and so never a
  #     candidate for the bare "Sync" check `sync_references` runs. Its two actions are Devise
  #     password validation
  #     (`User.find_for_authentication`/`valid_for_authentication?`) and `Device.register!`; zero
  #     `Sync::` (which, since Task 4, is also the only way to spell what used to be `Storage::`)
  #     or engine-model references of its own.
  #   - `test_users_controller.rb`: a dev/test-only Devise signup seam, gated on
  #     `ENABLE_TEST_SIGNUP` (never set on managed production), that lets the Rust integration
  #     tests create a confirmed account before enrolling a device via `POST /v1/devices/login`.
  #     It does not even inherit `V1::BaseController` -- it is `< ActionController::API` directly
  #     -- and touches only `User`.
  #
  # Both would otherwise be exempted from the maker-layer scan below for having done nothing wrong
  # -- the same false safety a `Version.count` planted in either used to pass under (mutation-
  # checked: GREEN before this rejection existed, matching the fourteen-controller carve-out's own
  # history). `end_with?` on the relative-glob suffix, not `File.basename`, so a same-named file
  # elsewhere in the tree (there is none today) could never be silently swept up by this rejection
  # too.
  # THE BOUNDARY IS PHYSICAL NOW, AND THAT MAKES THIS GUARD STRONGER RATHER THAN WEAKER -- but it
  # had to be repointed, and for a while after Phase B's move it silently was not.
  #
  # WHAT WENT WRONG, because it is the most instructive thing in this file: SYNC_SIDE_GLOBS listed
  # paths under app/ and lib/. Phase B moved all 51 of those files into engines/tinkerex-sync/, so
  # the globs matched **three** files afterwards -- two of which are the HOST controllers the list
  # exists to exclude. Measured, not feared: a `Maker::` reference planted in the engine's own
  # sync/gc.rb left the suite GREEN. The guard that proves the engine can run without the maker
  # layer had gone blind to the engine.
  #
  # A directory is a better answer than a glob list ever was. The engine is now one tree; anything
  # inside it is engine, anything outside is host. There is no list to keep in step with a move,
  # which is exactly the failure this replaced.
  # THE TWO ENGINE-SIDE GUARDS LIVE IN THE ENGINE'S OWN REPOSITORY NOW, AND THAT IS NOT A
  # DEMOTION -- IT IS THE ONLY PLACE THEY CAN STILL FAIL.
  #
  # "the sync engine never reaches into the maker layer's features" and "the sync engine never
  # names a host constant" both scanned engines/tinkerex-sync/**. The 2026-08-20 extraction moved
  # that directory into chaim354/tinkerex-sync, so the glob started returning [] -- and both tests
  # are `assert_empty offenders`, which an empty file list satisfies perfectly. They would have
  # gone on passing forever over nothing, which is this repo's own recorded worst failure shape.
  # Only ONE of the pair said so: the stale-exception check inside the second test flunked because
  # CAPABILITY_GATE_HOST_REFERENCE_EXCEPTIONS still named a file that no longer existed. The first
  # test went green. That asymmetry is the argument for the third guard the engine repo now
  # carries, which asserts its own file list is non-empty before trusting either scan.
  #
  # They are now tinkerex-sync's test/architecture_test.rb, same detectors, same HOST_CONSTANTS
  # list, same single sanctioned exception (its FileLayer::Chunk port adapter), re-mutation-checked
  # there. Do NOT reconstruct them here against the installed gem: a guard that reads a vendored
  # copy of someone else's source reports on whatever revision Gemfile.lock happens to pin, so it
  # would go green on a stale pin while the engine's own main branch was broken -- and the engine
  # repo's CI is the thing that should be red in that case.
  #
  # WHAT STAYS HERE IS THE OTHER DIRECTION, and it is unaffected by the move: the maker layer
  # reaching INTO the engine is a fact about THIS repo's files, which are still here to be scanned.

  test "no maker-layer file names Sync:: or a bare engine model at all" do
    # READ ORDER WARNING: the comment block below is a CHRONOLOGICAL NARRATIVE and several of its
    # paragraphs are written in the present tense about states that no longer hold. In particular
    # "SYNC_SEAM_EXCEPTIONS is back" (Stage 3a Task 1) and "still names only app/models/user.rb"
    # (Stage 3b Phase A Task 2) describe a constant that **NO LONGER EXISTS** -- Arc D Part 2
    # deleted it, and this test now asserts ZERO with NO allowlist. That correction is recorded
    # below the assertion rather than here, which is the wrong way round for anyone reading top
    # to bottom; this note is the fix for the read order, not a replacement for the history.
    # (Found by auditing CLAUDE.md's guard claims, 2026-08-25: `grep SYNC_SEAM_EXCEPTIONS` returns
    # eight hits and zero definitions.)
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
    #
    # STAGE 3b PHASE A TASK 2 WIDENS THE FILE SET, NOT THE DETECTOR THIS TIME -- `sync_references`
    # itself needs no change to read a `.rake` file (Ripper lexes it identically to a `.rb` file;
    # it does not filter by extension), only the DISCOVERY globs did, since `app/**/*.rb` is
    # `.rb`-only and `lib/` was invisible to this scan entirely until now. See SYNC_SIDE_GLOBS's
    # own comment above for which two `lib/` files that makes engine-side (and so subtracted out
    # here same as any other), and for why `lib/schema_map.rb` is swept INTO this scan but never
    # flagged BY it.
    #
    # STAGE 3b PHASE A TASK 3 NARROWS THE DETECTOR BACK, WITHOUT NARROWING THE RULE -- the bare
    # engine model names ENGINE_MODELS used to enumerate are gone from `sync_references` because
    # they are gone from Ruby: every one of the eight now lives under `Sync::`, so the only
    # spelling left that reaches one already carries the bare "Sync" token this detector still
    # checks. This test's own behaviour is unaffected by the simplification -- SYNC_SEAM_EXCEPTIONS
    # still names only app/models/user.rb, because the ONE real violation Task 1's widening found
    # (sharing/links.rb) was already fixed by Task 6 moving the file, well before Task 3 touched
    # anything here, and user.rb's presence on the list comes from ENGINE_ASSOCIATIONS (`:on_ident`
    # matches on `versions`, `chunks`, etc.), a completely separate mechanism Task 3 does not touch.
    # EVERYTHING IN app/ AND lib/ IS HOST, FULL STOP. This used to subtract `engine_side_files`,
    # which was already a no-op after Phase B (the engine sat under engines/, matched by neither
    # glob) and became meaningless when the 2026-08-20 extraction took that directory out of the
    # repository altogether. Subtracting an empty set is not a safety net; it is a line that makes
    # a future reader look for a boundary inside app/ and lib/ that has not existed for two stages.
    #
    # NON-VACUITY, ASSERTED PER ARM RATHER THAN ON THE TOTAL (§14e). `assert_empty offending_files`
    # over zero files passes forever, and the three arms are wildly different sizes — 169 / 3 / 5
    # today — so a single floor on the combined 177 cannot see either small arm go empty, which is
    # the only realistic degradation here. `refute_empty`, not a number: `lib/tasks/*.rake` legitimately
    # shrinks (engine_schema.rake left with the engine), and a floor of "however many there are
    # today" would go red for the wrong reason the next time a task file is deleted.
    app_files  = Dir.glob(ROOT.join("app", "**", "*.rb"))
    lib_files  = Dir.glob(ROOT.join("lib", "**", "*.rb"))
    rake_files = Dir.glob(ROOT.join("lib", "tasks", "*.rake"))

    refute_empty app_files,  "app/**/*.rb matched nothing — this scan is vacuous (CLAUDE.md §14e)"
    refute_empty lib_files,  "lib/**/*.rb matched nothing — this scan is vacuous (CLAUDE.md §14e)"
    refute_empty rake_files, "lib/tasks/*.rake matched nothing — this scan is vacuous (CLAUDE.md §14e)"

    maker_layer_files = app_files + lib_files + rake_files

    hits = maker_layer_files.flat_map { |file| sync_references(file) }
    offending_files = hits.map { |hit| hit.split(":").first }.uniq.sort

    # ZERO, WITH NO ALLOWLIST -- WHICH IS A STRONGER CLAIM THAN THIS TEST HAS EVER MADE.
    #
    # This was `extra`/`stale`/`assert_not_empty SYNC_SEAM_EXCEPTIONS`: a named allowlist, checked
    # in both directions so a mutation could not swap one offender for another, plus a third
    # assertion that the list must DIE WITH ITS LAST ENTRY rather than linger empty. That third
    # assertion is what fired when Arc D Part 2 removed the wiring, and its message said exactly
    # what to do here -- delete the constant, collapse to one assert_empty. Doing what a guard
    # tells you when it goes red is the whole point of having written it that way.
    #
    # The rule it enforces is unchanged in spirit and wider in fact: CLAUDE.md §14d's tripwire,
    # "if a maker-layer change needs to touch sync, the changelog, conflicts, locks, or the
    # mounts, the boundary is wrong -- stop." It used to mean "route it through FileLayer::Chunk".
    # There is no FileLayer::Chunk any more and no engine in this process, so the honest answer to
    # a new hit here is not "use the port" but "that work belongs in chaim354/tinkerex-sync".
    #
    # NAMED, NOT COUNTED, still: the message lists the files, matching this file's own rule from
    # the chunk-internals test above that a count alone cannot tell one offender from another.
    assert_empty offending_files,
                 "maker-layer file(s) reaching into Sync:: or a bare engine model directly:\n" \
                 "  #{offending_files.join("\n  ")}\n" \
                 "The sync engine is not a dependency of this app (Arc D Part 2) -- these " \
                 "constants do not resolve here at all, so this is a NameError waiting for the " \
                 "code path to run, not a style violation. If the work genuinely belongs to the " \
                 "engine, it belongs in chaim354/tinkerex-sync; if it belongs to this app, it " \
                 "goes through FileLayer.current like every other library operation."
  end

  # STAGE 3a TASK 5 (boundary design §3; docs/superpowers/plans/2026-08-20-stage-3a-decouple-the-engine.md).
  # V1::BaseController is inherited by all FOURTEEN v1/maker/* controllers, so a Sync:: or
  # Storage:: reference here -- even one sitting inside a method body, never mind one that
  # resolves at class-definition time the way `rescue_from` does -- makes the maker API's own
  # base class name the sync engine. That used to be literally true: `rescue_from
  # Sync::Commit::InvalidManifest` and `rescue_from Sync::Commit::KindConflict` resolved their
  # argument to a real exception class the moment this file's class body ran, and a
  # `before_action :stash_request_base_url` whose body touched Storage::ChunkStore /
  # Storage::LocalChunkStore ran on every v1 request regardless of controller. Task 5 moved both
  # down to the two controllers that can actually raise/need them (V1::CommitsController,
  # V1::ChunksController, plus the app/controllers/concerns/v1/stash_request_base_url.rb concern).
  #
  # THIS IS INVISIBLE TO THE TWO TESTS ABOVE, AND DELIBERATELY SO. base_controller.rb sits under
  # `app/controllers/v1/**/*.rb`, which SYNC_SIDE_GLOBS already treats as sync-side -- correctly,
  # since V1::CommitsController and V1::ChunksController live in the very same directory and DO
  # need to name Sync::/Storage::. So "the maker layer reaches into the engine" never scans this
  # file at all; it is not maker-layer code by that test's own (correct) definition. What makes
  # base_controller.rb different from its siblings in that same directory is that EVERY v1/maker/*
  # controller inherits from it specifically -- a fact no glob-based scan can express, since it is
  # about the constant graph (who subclasses whom), not about which directory a file sits in. A
  # dedicated, narrow guard on this one file is cheaper than teaching the shared scan to carve an
  # exception out of a glob it already, correctly, includes.
  #
  # STAGE 3b PHASE A TASK 4 DELETES THE DEDICATED `storage_hits` RIPPER PASS THAT USED TO SIT HERE
  # -- the same "detector narrows, rule doesn't" shape as Task 3's ENGINE_MODELS deletion (see the
  # note above `sync_references`, and the one below it where ENGINE_MODELS used to live). `Storage`
  # moved to `Sync::Storage` (the STAGE 3b PHASE A TASK 4 paragraph above SYNC_SIDE_GLOBS), so the
  # only spelling that could still reach it from this file is `Sync::Storage::ChunkStore` -- which
  # already carries the bare "Sync" token `sync_references` has ALWAYS checked. A bare top-level
  # `Storage` reference here today would not reach this assertion at all: Zeitwerk would raise
  # `NameError: uninitialized constant Storage` the moment it tried to resolve it, before this test
  # runs.
  #
  # THE ORIGINAL REASON THE TWO CHECKS WERE KEPT SEPARATE -- folding a bare-Storage check into
  # `sync_references` itself would have made Maker::Addons::LibraryOutput's OWN legitimate
  # `Storage::ChunkStore` reference a second, unrelated thing to exempt in the maker-layer scan
  # above -- is now moot, for a DIFFERENT reason than the one this paragraph used to give:
  # library_output.rb had to join SYNC_SEAM_EXCEPTIONS regardless of what THIS test does, because
  # Task 4's rename made its reference visible to `sync_references` on its own (see the note
  # there). This change does not touch `sync_references` itself -- it only retires a second,
  # now-provably-unreachable pass that used to run beside it. The test's NAME and its PROTECTION
  # are UNCHANGED: a `Storage::` reference in base_controller.rb is still forbidden, just caught
  # the same way any other `Sync::` reference already was.
  # (library_output.rb ITSELF IS GONE FROM SYNC_SEAM_EXCEPTIONS NOW, per Arc B Task 2 -- see the
  # note above that constant. Its `Storage::ChunkStore` reference, the thing this paragraph is
  # explaining the history of, no longer exists; the history stands because it explains why the
  # dedicated Ripper pass was retired, not because the file is still on the list today.)
  #
  # STAGE 3b PHASE B TASK 7 RELAXES "ZERO" TO "EXACTLY ONE, AND ONLY THAT ONE" -- NOT A RETREAT,
  # A DIFFERENT WORLD. This test's own reasoning, up to now, was that a Sync:: reference here
  # "forces the whole sync engine to load just to parse the maker API" -- true when Sync:: was
  # in-repo code sharing this app's Zeitwerk tree, so an eager reference could pull in a heavy
  # dependency graph a share/s3 request never needed. It stopped being true the moment tinkerex-sync
  # became a real gem: `gem "tinkerex-sync", path: "engines/tinkerex-sync"` is REQUIRED at
  # Bundler.require time, unconditionally, on every LIBRARY_BACKEND, before a single line of this
  # app's own code is even autoloaded -- there is no longer a "parse the maker API without loading
  # the sync engine" outcome for this guard to protect. What replaced it is a NEW, NARROWER
  # question this task's own V1::BaseController split had to answer for real (see
  # app/controllers/v1/base_controller.rb's header for the three-option decision): the engine now
  # ships a base controller that carries Authentication/the generic rescues (and, since Stage 3b
  # Task 9, its own CapabilityGate in place of what used to be a direct `LibraryCapabilities`
  # include -- see Sync::V1::BaseController's header).
  #
  # THE DIRECTION REVERSED ON 2026-08-21, AND THE ASSERTION REVERSED WITH IT. Phase B had
  # `class BaseController < Sync::V1::BaseController`, so the fourteen v1/maker/* controllers rode
  # the engine's v1 infrastructure. That is unsurvivable once share/s3 stop loading the engine: a
  # superclass is resolved when the class body loads, so the maker app's own API had no base class
  # and could not eager-load. The host now stands on ActionController::API with its own copy of the
  # device-auth concern. The engine's base is UNCHANGED and still right for a bare mount -- both
  # directions cannot be true of one class, which is why this became a design decision rather than
  # a guard tweak.
  #
  # WHAT THIS TEST STILL ENFORCES IS THE SAME INVARIANT IT ALWAYS DID, only stricter: this file may
  # now name NO Sync:: constant at all, where before it could name exactly one. Nothing may creep
  # back in -- a rescue_from reaching into the engine, a before_action, a stray call -- the shape
  # Stage 3a Task 5 removed and this test has guarded ever since.
  test "V1::BaseController names no Sync:: or Storage:: constant at all" do
    path = ROOT.join("app/controllers/v1/base_controller.rb")
    hits = sync_references(path.to_s)

    superclass_line = path.readlines.find { |l| l.include?("class BaseController <") }
    assert superclass_line&.include?("ActionController::API"),
           "expected app/controllers/v1/base_controller.rb to declare " \
           "`class BaseController < ActionController::API` -- found #{superclass_line.inspect}. " \
           "Inheriting the engine's base again makes share/s3 unable to load the maker v1 API."

    # ZERO, AND THE MESSAGE USED TO SAY "EXACTLY ONE" -- a stale claim sitting beside a correct
    # assertion, which is the shape CLAUDE.md §15 warns about and is worth naming rather than
    # quietly correcting. It described Phase B, when this class inherited Sync::V1::BaseController
    # and that superclass line was the one sanctioned reference. §14j reversed that direction (an
    # engine base class here made the maker v1 API unloadable without the engine), and Arc D Part 2
    # removed the engine entirely, so the count has been 0 for two stages while the sentence
    # explaining it still described one.
    assert_equal 0, hits.size,
                 "V1::BaseController must reference NO Sync:: or Storage:: constant at all -- " \
                 "found #{hits.size}:\n  #{hits.join("\n  ")}\n" \
                 "All fourteen v1/maker/* controllers inherit this class, and the sync engine is " \
                 "not a dependency of this app (Arc D Part 2), so such a reference does not " \
                 "resolve here -- it is a NameError waiting for the code path to run. Work that " \
                 "genuinely needs those constants belongs in chaim354/tinkerex-sync."
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
    #
    # 172 files today; the floor is a plausibility check, not a count (see `offending`). `app` and
    # `lib` are Rails-fixed, so the realistic degradation here is the glob itself being edited
    # rather than the tree moving — either way an empty scan is an `assert_empty` that passes.
    hits = offending(%w[app lib], /rescue.*NotImplementedError/, minimum: 100)

    assert_empty hits,
                 "NotImplementedError must never be rescued (CLAUDE.md §14a), found:\n" \
                 "  #{hits.join("\n  ")}\n" \
                 "It is a ScriptError, so this rescue does not do what it looks like it does. " \
                 "Gate on the capability before the call instead — see LibraryCapabilities."
  end

  # A BARE ArgumentError IS A PROGRAMMING ERROR, SO NO CONTROLLER ANSWERS ONE (F-S18-1, 2026-10-19):
  # V1::BaseController's `rescue_from ArgumentError` turned arity drift and misconfiguration into a
  # 422 carrying the interpreter's message. READ OFF EACH CLASS'S rescue_handlers, NOT ITS FILE, so a
  # multi-line, quoted or inherited declaration cannot hide. The probes pin BOTH directions: the bare
  # class is seen, and a NAMED SUBCLASS (Maker::MoveNode::InvalidName, the shape a client-input case
  # takes) is not -- a check widened to subclasses would pass today only because none is rescued yet.
  test "no controller rescue_froms a bare ArgumentError" do
    bare = ->(klass) { klass.rescue_handlers.map(&:first).select { |name| name.safe_constantize == ArgumentError } }
    probe = ->(error) { Class.new { include ActiveSupport::Rescuable; rescue_from(error) { } } }
    assert_equal [ "ArgumentError" ], bare.(probe.(ArgumentError)), "the check must see the bare class"
    assert_empty bare.(probe.(Maker::MoveNode::InvalidName)), "a named subclass is the sanctioned shape"

    # AN ANONYMOUS CONTROLLER HAS NO NAME, and const_source_location raises on one (NameError for "",
    # TypeError for nil) in whichever test order first builds it. Skipped before the lookup; probed here.
    Rails.application.eager_load!
    anonymous = Class.new(ActionController::API)
    scanned = [ ActionController::Base, ActionController::API ].flat_map(&:descendants)
    assert_includes scanned, anonymous, "the probe must be in the set the scan walks"
    controllers = scanned.select do |klass|
      next false unless klass.name
      Object.const_source_location(klass.name)&.first.to_s.start_with?(ROOT.join("app/controllers/").to_s)
    end
    assert_includes controllers, V1::BaseController, "the scan must reach the class it was written for (§14e)"

    offenders = controllers.flat_map { |klass| bare.(klass).map { |name| "#{klass.name}: rescue_from #{name}" } }
    assert_empty offenders, "a bare ArgumentError must 500 with its backtrace (F-S18-1), but these answer " \
                            "it:\n  #{offenders.join("\n  ")}\nRescue a NAMED subclass instead " \
                            "(Maker::MoveNode::InvalidName is the precedent)"
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

  # A PUBLIC PAGE NEVER READS THE SESSION (stage 3, S3-4; spec §6, CLAUDE.md §14d). This is the
  # OTHER half of the test above: that one says every ApplicationController descendant authenticates,
  # and the honest way to have a page that does not is to stand outside that tree entirely rather
  # than to `skip_before_action` inside it. Both halves are asserted here, because either alone is
  # satisfiable while the rule is broken — a `Public::` controller could descend from
  # ApplicationController and skip the callback (caught by the superclass/descendant assertions), or
  # keep the right superclass and still read `current_user` through a helper (caught by the scan).
  #
  # THE SCAN MATCHES ACCESSOR FORMS, NOT THE WORD. `session` and `cookies` appear in this
  # namespace's own PROSE — base_controller.rb says "a public page never reads the session" in as
  # many words — so a bare /session/ would be red on the code that is correct, which is the shape
  # `offending` documents above and the reason both comment kinds are stripped here. `session[` /
  # `session.` and `cookies[` / `cookies.` are the reads; the four accessors are matched as whole
  # words.
  #
  # ERB COMMENTS ARE STRIPPED AS BLOCKS, NOT AS LINES, because `<%# … %>` spans them: every template
  # in this namespace opens with a multi-line comment, and a line-oriented strip would either miss
  # their interiors or (with a `<%#`-prefix rule) miss nothing at all. The stripper carries the open
  # state across lines and keeps whatever follows the terminator on the same line, so real code
  # sharing a line with a comment's end is still scanned.
  #
  # NON-VACUOUS BY ASSERTION (§14e): the scan is 30 files today (8 controllers, 13 templates —
  # public/projects/_page.html.erb among them since stage 4, S4-4 extracted the page body — and the
  # 8 shared viewer partials under app/views/files/viewers, which S4-5 added because a PUBLIC page
  # renders them from OUTSIDE this namespace) and a renamed directory would otherwise retire this
  # invariant with `assert_empty` passing over zero files. 18 is a plausibility floor, not today's
  # count.
  test "the Public namespace stands outside ApplicationController and names no session accessor" do
    Rails.application.eager_load!

    assert_equal ActionController::Base, Public::BaseController.superclass,
                 "Public::BaseController must stand on ActionController::Base — an " \
                 "ApplicationController descendant would need a `skip_before_action`, which the " \
                 "test above exists to flag"
    publics = ApplicationController.descendants.select { |klass| klass.name.to_s.start_with?("Public::") }
    assert_empty publics.map(&:name),
                 "a Public:: controller descends from ApplicationController; the namespace is " \
                 "sessionless by construction, not by skipping a callback"

    files = (Dir.glob(ROOT.join("app", "controllers", "public", "**", "*.rb")) +
             # EVERY TEMPLATE KIND, not `*.erb`: the namespace's first non-ERB template was the Atom
             # builder (stage 3, S3-6), and a `*.erb` glob let `session[:who]` sit in it with this
             # guard green (mutation-proven by S3-6's review). A template is a template.
             Dir.glob(ROOT.join("app", "views", "public", "**", "*.{erb,builder,jbuilder}")) +
             # STAGE 4, S4-5: THE VIEWER PARTIALS ARE SHARED, SO THE SCAN HAS TO REACH THEM. A
             # visitor's file page renders app/views/files/viewers/*, which live OUTSIDE this
             # namespace — a `current_user` in one of them would reach a visitor with this guard
             # green (a private ROUTE HELPER too, which the second arm below is for). They take
             # every URL as a strict local precisely so they need not know which page they are on;
             # this is what checks that they don't.
             Dir.glob(ROOT.join("app", "views", "files", "viewers", "*.erb")) +
             # STAGE 4, S4-5: THE VISITOR'S HEADER lives under layouts/ because the layout's anonymous
             # branch renders it, and a public controller's view context DOES resolve `current_user`
             # (probed in review) — so a session read there would render silently, not raise.
             Dir.glob(ROOT.join("app", "views", "layouts", "_public_header.html.erb"))).sort
    assert_operator files.size, :>=, 18,
                    "the Public scan matched #{files.size} file(s), below the plausibility floor " \
                    "of 18 — so `assert_empty` below cannot fail for the reason it exists " \
                    "(CLAUDE.md §14e). A renamed or moved directory is the usual cause, and the " \
                    "eight shared viewer partials (files/viewers/_image _pdf _kicanvas _gerber " \
                    "_code _model3d _measure _static) are half of what the floor now counts"

    offenders = files.flat_map do |file|
      erb_open = false
      File.readlines(file, chomp: true).each_with_index.filter_map do |line, idx|
        code, erb_open = strip_erb_comment(line, erb_open)
        next if code.lstrip.start_with?("#")
        next unless code.match?(SESSION_ACCESSOR)
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}"
      end
    end

    assert_empty offenders,
                 "a public controller or view reads the session:\n  #{offenders.join("\n  ")}\n" \
                 "A public page is a 404 to everyone for a private project — including its own " \
                 "signed-in owner — precisely because it cannot know who is looking. A template " \
                 "that branches on the visitor makes the page disagree with the file route."

    # THE VIEWER PARTIALS GET A SECOND ARM, FOR ROUTE HELPERS (stage 4, S4-5, found in review).
    # SESSION_ACCESSOR has no route-helper pattern — the namespace's own templates call
    # `public_*_path` legitimately — so a shared viewer partial that called `blob_file_path("id")`,
    # a PRIVATE byte route, rendered `<a href="/files/…/blob">` on a visitor's page with the scan
    # above green (mutation-proven). Strict locals are the design that stops it: every URL a viewer
    # needs arrives as a local, so NO `*_path`/`*_url` identifier may appear in one except the locals
    # its own `locals:` line declares — read off the partial itself, so the allowlist cannot drift
    # from the signature. `url_for(thumbnail.asset)` (Active Storage) is not matched: the pattern
    # wants the `_path`/`_url` SUFFIX a route helper carries.
    viewer_files = files.select { |f| f.include?("/app/views/files/viewers/") }
    assert_operator viewer_files.size, :>=, 8, "the viewer-partial scan matched #{viewer_files.size} file(s)"
    viewer_offenders = viewer_files.flat_map do |file|
      lines = File.readlines(file, chomp: true)
      declared = lines.first.to_s.scan(/(\w+):/).flatten
      erb_open = false
      lines.each_with_index.filter_map do |line, idx|
        code, erb_open = strip_erb_comment(line, erb_open)
        helpers = code.scan(/\b([a-z_]+_(?:path|url))\b/).flatten.uniq - declared
        next if helpers.empty?
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1} (#{helpers.join(', ')})"
      end
    end
    assert_empty viewer_offenders,
                 "a shared viewer partial calls a route helper instead of taking the URL as a strict " \
                 "local — a private route would reach a visitor's page:\n  #{viewer_offenders.join("\n  ")}"

    # A THIRD ARM, FOR `url_for` — WHICH THE ARM ABOVE DELIBERATELY DOES NOT MATCH and says so
    # (hardening, 2026-09-08; tinkerex#278). That pattern wants the `_path`/`_url` SUFFIX a route
    # helper carries, so `url_for(thumbnail.asset)` sailed past it — and an Active Storage blob URL
    # is worse than a private route helper on a public page, not better: it is UNAUTHENTICATED and
    # it NEVER EXPIRES (`ActiveStorage.urls_expire_in` is nil), so a cover thumbnail kept answering
    # after its project went private, and forever. The fix is the same design the arm above
    # enforces — the URL arrives as a strict local (`thumbnail_url:`, `url:`), built by the maker's
    # page with `preview_src` and by a visitor's with `Maker::PublicProject#preview_url_for` — so
    # the check is simply that neither kind of partial builds one at all.
    #
    # `files/_thumb.html.erb` JOINS THE EIGHT even though it is not a viewer: it is rendered by
    # eleven private surfaces AND by three public ones, which is the same sharing for the same
    # reason, and it was the emitter that shipped the never-expiring cover.
    #
    # AND EVERY PUBLIC TEMPLATE JOINS TOO, FOR `url_for` AND FOR `preview_src` (found in review,
    # 2026-09-08). Public::BaseController stands on ActionController::Base, but Rails still puts
    # ApplicationHelper in its view context, so `preview_src` — the ONE private spelling, `url_for`
    # over the asset — is callable from a public template; measured, swapping one public call site
    # to it rendered a blob URL into the Photos panel with this guard and the whole project-page
    # suite green. Scanning only the shared partials guarded the emitters that shipped and not the
    # next one a public panel would copy.
    #
    # ERB COMMENTS ARE STRIPPED, so the several comments naming `url_for(asset)` as the thing NOT to
    # write are not offenders — the same stripper both arms above use, carrying its open state
    # across lines.
    thumb_partial = ROOT.join("app", "views", "files", "_thumb.html.erb").to_s
    assert File.exist?(thumb_partial),
           "app/views/files/_thumb.html.erb is gone — a moved file must not retire this arm silently"
    # Every TEMPLATE the first arm scans (the public namespace's own, the viewers, the visitor's
    # header) plus `_thumb`; the controllers are left out because `url_for` in one is a redirect,
    # not a URL in a visitor's document.
    url_for_files = (files.reject { |f| f.end_with?(".rb") } + [ thumb_partial ]).uniq
    assert_operator url_for_files.size, :>=, 20,
                    "the url_for scan matched #{url_for_files.size} file(s), below the floor of 20 " \
                    "(the public templates, 8 viewer partials, the public header and files/_thumb) " \
                    "— `assert_empty` below cannot fail for the reason it exists (CLAUDE.md §14e)"
    url_for_offenders = url_for_files.flat_map do |file|
      erb_open = false
      File.readlines(file, chomp: true).each_with_index.filter_map do |line, idx|
        code, erb_open = strip_erb_comment(line, erb_open)
        next unless code.match?(/\b(url_for|preview_src)\b/)
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}"
      end
    end
    assert_empty url_for_offenders,
                 "a shared partial or a public template builds an Active Storage URL (`url_for`) or " \
                 "names the private spelling of one (`preview_src`) instead of taking the URL as a " \
                 "strict local or asking Maker::PublicProject#preview_url_for — a blob URL is " \
                 "unauthenticated and never expires, so a public page's picture outlives the " \
                 "project's publication:\n  #{url_for_offenders.join("\n  ")}"
  end

  SESSION_ACCESSOR = /\b(current_user|user_signed_in\?|web_device)\b|\bsession\s*[\[.]|\bcookies\s*[\[.]/

  # `line` with every `<%# … %>` region removed, plus whether a comment is still open at its end.
  # Returns [code, still_open]. A `.rb` file contains no `<%#` at all, so this is a no-op there and
  # the two file kinds can share one loop.
  def strip_erb_comment(line, open)
    out = +""
    rest = line
    loop do
      if open
        idx = rest.index("%>")
        return [ out, true ] unless idx

        rest = rest[(idx + 2)..]
        open = false
      else
        idx = rest.index("<%#")
        unless idx
          out << rest
          return [ out, false ]
        end

        out << rest[0...idx]
        rest = rest[(idx + 3)..]
        open = true
      end
    end
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
  # THE THREE EXTENSION LISTS ARE ONE OBJECT, NOT TWO EQUAL ONES (stage 4, S4-5). FilePreview owns
  # them because constant lookup inside a module method is lexical; FilesController re-exposes them
  # because places outside that file cite `FilesController::KICANVAS_EXTS` and friends —
  # FilesHelper#kicad?, Maker::GerberArchive, Maker::PublicProject and three test suites. An
  # `assert_equal` here would pass over a re-literal, which is exactly the drift the alias exists to
  # prevent — so this asserts IDENTITY. `SAFE_INLINE_TYPES` gets the same treatment for the same
  # reason (files_controller.rb argues it in prose; this is the guard behind the prose).
  test "the file-preview vocabularies are re-exposed on FilesController, never re-declared" do
    { MEASURABLE_EXTS: FilePreview::MEASURABLE_EXTS,
      KICANVAS_EXTS: FilePreview::KICANVAS_EXTS,
      GERBER_EXTS: FilePreview::GERBER_EXTS }.each do |name, owned|
      assert_same owned, FilesController.const_get(name),
                  "FilesController::#{name} is a SECOND list, not the concern's own — a re-literal " \
                  "passes assert_equal and drifts on the next edit"
    end
    assert_same FileDelivery::SAFE_INLINE_TYPES, FilesController::SAFE_INLINE_TYPES
  end

  # A PREVIEW'S `ready` AND `rebuilding` ARE ASKED OF Maker::Preview, NEVER COMPARED AT THE CONSUMER,
  # AND NOTHING RE-SPELLS THE IN-FLIGHT SET (F-S08-2, 2026-10-20). `rebuilding` split `ready` in two —
  # "a picture of this content" and "the build these coordinates name" — and a reader still
  # comparing `status == "ready"` picks one meaning by accident: a picture surface blanks a correct
  # picture for a whole rebuild, and a re-spelled `%w[pending processing]` silently leaves
  # `rebuilding` out of what it calls in flight. The predicates (`in_flight?`, `showable?`,
  # `current_build?`, `servable?`, `failed?`) are the vocabulary, defined in the one file this sweep
  # exempts.
  #
  # EXACTLY THOSE TWO WORDS AND THAT ONE SET. A literal that means one thing is not policed: the
  # job's start asks `status == "pending"`, and the geometry polls' terminal arm is `when "failed",
  # "unsupported"`. COMPARISONS ONLY: a wire answer that SAYS "ready" (`render json: { status:
  # "ready" }`) and the job's writes (`update!(status: "ready")`) are not readers and do not match.
  # Whole-line Ruby comments and ERB comments are skipped: several partials describe the old
  # spelling in prose.
  PREVIEW_STATUS_COMPARISON = /
    (?:[!=]=|\bwhen\b[^\n]*?)\s*["'](?:ready|rebuilding)["']   # status == "ready", when "ready"
    | ["'](?:ready|rebuilding)["']\s*[!=]=                       # "ready" == status
    | %w[\[(][^\])]*\b(?:ready|rebuilding)\b                     # %w[ready rebuilding].include?
    | %w[\[(](?=[^\])]*\bpending\b)(?=[^\])]*\bprocessing\b)    # the in-flight set, re-spelled
  /x

  test "no consumer compares a preview's status to ready or rebuilding, or re-spells the in-flight set" do
    # THE PATTERN ITSELF, ASKED FIRST. A regex that stopped matching would sweep every file below and
    # find nothing, which `assert_empty` reads as success — §14e's vacuous guard, one level in.
    [ 'thumb&.status == "ready"', 'when "rebuilding"', '%w[pending processing].include?(s)' ].each do |offender|
      assert_match PREVIEW_STATUS_COMPARISON, offender, "the pattern no longer catches #{offender}"
    end
    [ 'render json: { status: "ready", url: u }', 'update!(status: "ready")', 'status == "pending"' ].each do |fine|
      assert_no_match PREVIEW_STATUS_COMPARISON, fine, "the pattern now refuses #{fine}"
    end

    model = ROOT.join("app/models/maker/preview.rb").to_s
    files = Dir.glob(ROOT.join("app", "**", "*.{rb,erb}").to_s).sort - [ model ]
    # NON-EMPTY ON BOTH HALVES (§14e): the readers are mostly templates, so an ERB glob that stopped
    # matching would retire most of this guard while the Ruby half kept it looking alive.
    assert_operator files.size, :>=, 300, "app/**/*.{rb,erb} matched only #{files.size} files"
    assert_operator files.count { |f| f.end_with?(".erb") }, :>=, 100, "the ERB half matched too few files"

    offenders = files.flat_map do |file|
      text = File.read(file)
      text = text.gsub(/<%#.*?%>/m) { |comment| "\n" * comment.count("\n") } if file.end_with?(".erb")
      text.lines.each_with_index.filter_map do |line, idx|
        next if file.end_with?(".rb") && line.lstrip.start_with?("#")
        next unless line.match?(PREVIEW_STATUS_COMPARISON)

        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}: #{line.strip}"
      end
    end

    assert_empty offenders,
                 "A preview's status compared to ready or rebuilding, or the in-flight set re-spelled, " \
                 "outside Maker::Preview:\n  " \
                 "#{offenders.join("\n  ")}\nAsk the row: `showable?` to SHOW its asset (ready, or an " \
                 "older build while it rebuilds), `current_build?` to MEASURE from it, `in_flight?` " \
                 "for a job believed coming, `failed?` for the retryable terminal state."
  end
end
