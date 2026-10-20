require "test_helper"

# Guards the SPLIT between CLAUDE.md and docs/invariants/ — a structure the Rails process never
# loads, so no other test in the suite can see it. Modelled on test/ci_hygiene_test.rb and
# test/deploy_hygiene_test.rb, which guard workflow and deployment facts for the same reason.
#
# WHY THIS EXISTS. CLAUDE.md is loaded into an agent's context on EVERY session, so its length is a
# tax on every future task. On 2026-08-25 it was 2,449 lines / ~51k tokens, of which §14c (addons),
# §14g (deploy secrets), §14h (the Measure view) and §14i (backup) were ~1,000 lines that bind only
# when you are inside those areas. They moved to docs/invariants/<area>.md, each leaving a stub
# under its original §14 anchor — the anchor has to stay, because code comments cite `§14c` and
# `§14h` by number and a citation that resolves to nothing is worse than a long file.
#
# The two failure modes this guards, both silent:
#
#   * A STUB LOSES ITS FILE. Somebody deletes or renames docs/invariants/addons.md and the §14c stub
#     goes on pointing at it. Nothing errors — the next agent simply reads a pointer to nowhere and
#     proceeds without ~90 invariants, which is precisely the "green suite over something that never
#     worked" shape CLAUDE.md §15 names as this repo's dominant failure.
#   * AN INVARIANTS FILE LOSES ITS STUB. Somebody adds docs/invariants/<new>.md and never cites it
#     from CLAUDE.md, so it is never loaded by anything and never read by anyone. Same outcome,
#     opposite direction.
#
# THE NON-EMPTY ASSERTION IS NOT DECORATION. CLAUDE.md §14e records two architecture guards that
# were `assert_empty offenders` over a glob, and went on PASSING OVER NOTHING once the directory
# they scanned was moved away. Both checks below assert their scanned set is non-empty before
# trusting what it reports.
class DocsHygieneTest < ActiveSupport::TestCase
  CLAUDE_MD = Rails.root.join("CLAUDE.md")
  INVARIANTS_DIR = Rails.root.join("docs/invariants")

  # The ceiling is a RATCHET, not a target. It was 2,449 lines before the split. Lowering it as the
  # file shrinks is welcome; raising it is the thing to argue about in review, because every line
  # added here is paid on every session forever. If a rule genuinely needs the room, ask first
  # whether it is an AREA rule that belongs in docs/invariants/ instead — that is what the split is
  # for, and it costs the reader nothing.
  #
  # RATCHETED 1,350 -> 1,345 on 2026-08-26, when the file-type vocabulary rule moved to
  # docs/invariants/files-preview.md and CLAUDE.md fell to 1,342. Lowered rather than banked,
  # which is the whole point of calling it a ratchet: leaving the old number turns a real
  # reduction into eight lines of silent headroom for the next unrelated addition.
  #
  # RAISED 1,345 -> 1,355 on 2026-08-28 for the §14l stub pointing at docs/invariants/git-editing.md
  # (tinkerex#178) — the raise the paragraph above says to argue about in review, so here is the
  # argument. A stub pointing at an area file is the sanctioned pattern this test exists to protect,
  # not an exception to it: the 142 lines of git-editing invariants stayed OUT of CLAUDE.md, and what
  # landed is the ten-line pointer that makes them findable by the same mechanism every other area
  # file uses. The alternative — an invariants file with no §14 anchor — is one the two pointer tests
  # below would refuse outright, and it would leave `§14l` citations resolving to nothing, which this
  # file's own header calls worse than a long CLAUDE.md. Raised by EXACTLY what the stub cost.
  #
  # LOWERED 1,355 -> 1,354 ON 2026-08-31, WHICH IS THE RATCHET WORKING RATHER THAN A NEW RULE. The
  # CI-to-Unraid arc rewrote §15's four CI bullets and §12.6; the first draft came in FOUR LINES
  # OVER and the answer was to tighten that prose, not to raise this number. It landed one line
  # under, and banking that line for the next unrelated addition is exactly what a ratchet exists to
  # prevent. CLAUDE.md is 1,354 lines today.
  #
  # RAISED 1,354 -> 1,364 ON 2026-09-03 FOR THE §14m STUB pointing at docs/invariants/design-system.md
  # (the web shell and design system arc). The same argument as 14l, and the same shape: the twelve
  # rules of the design system stayed OUT of this file, and what landed is the ten-line pointer that
  # makes them findable by the mechanism every other area file uses. The file sat at EXACTLY the
  # ceiling when the arc began, so the raise is the stub's whole cost and not a line more — the
  # preamble's "Seven subsections" became "Eight" on its own line without wrapping.
  #
  # LOWERED 1,364 -> 1,363 ON 2026-10-09 (redesign slice 7): dropping the retired current-project
  # columns removed §14e's parenthetical about user.rb's stale comment, one line, and a ratchet banks
  # nothing.
  #
  # LOWERED 1,362 -> 1,360 ON 2026-10-14 (Phase 6, the maker half): §14j's first bullet lost the
  # bin/sync-server function it described, and §13 a sentence about a deploy.yml the sync repo deleted.
  #
  # LOWERED 1,360 -> 1,358 ON 2026-10-19 (audit slice S-1, suite honesty): §15's "bin/ci PRINTS the
  # three counts and never COMPARES them" became "bin/ci compares them" (Ci::LegRuns), two lines fewer.
  #
  # LOWERED 1,358 -> 1,356 ON 2026-10-19 (audit slice F-S01-1, one reading of LIBRARY_BACKEND): §14a's
  # two bullets about check!'s `chunk` default became one bullet about the reading that replaced it.
  MAX_LINES = 1_356

  test "CLAUDE.md stays under its line ceiling" do
    lines = CLAUDE_MD.readlines.size

    assert_operator lines, :<=, MAX_LINES, <<~MSG
      CLAUDE.md is #{lines} lines, over the #{MAX_LINES}-line ceiling.

      This file is loaded into an agent's context on EVERY session. Before raising MAX_LINES, ask
      whether what you added is an AREA invariant — one that binds only inside a subsystem. If so it
      belongs in docs/invariants/<area>.md with a stub under its §14 anchor, which costs the reader
      nothing on the sessions that never touch that area. See CLAUDE.md's own "How this file is
      scoped" preamble.
    MSG
  end

  # DELETING THE OLD STATUS FILE WALKS STRAIGHT INTO §14e's RECORDED TRAP — "a guard that scans a
  # directory dies silently when the directory leaves". Two architecture guards were `assert_empty`
  # over a glob of `engines/tinkerex-sync/**`, and the extraction made that glob `[]`, which
  # satisfies assert_empty perfectly. So this asserts its scanned set is NON-EMPTY first, and that
  # it is implausibly small.
  #
  # THE NEEDLE IS BUILT AT RUNTIME so this file does not contain the literal it forbids. The
  # alternative — excluding this file by name — is an exclusion that could later hide a real
  # citation added here. No exclusions is stronger than one exclusion.
  #
  # ONE DIRECTORY IS OUT OF SCOPE AND IT IS DELIBERATE: `.claude/worktrees/` holds OTHER BRANCHES'
  # checkouts. It is gitignored and untracked, and it held 222 of the 241 hits when this was
  # written — scanning it fails the guard on work that is not in this tree and not this branch's to
  # fix. CLAUDE.md is also unscanned: §11 names the retired path on purpose, to say where the
  # record went and to give `git show <sha>:` for it. A historical NAME is not a dead link.
  STATUS_SCAN_DIRS = %w[app lib test config .claude/commands].freeze
  RETIRED_RECORD = [ "docs", "STATUS.md" ].join("/").freeze

  test "no source file cites the retired status file" do
    files = STATUS_SCAN_DIRS.flat_map { |d| Dir.glob("#{d}/**/*.{rb,yml,yaml,md,js}", base: Rails.root) }

    refute_empty files, "the scan found no files at all — did the layout move? " \
                        "This test cannot guard a set it cannot find."
    assert_operator files.size, :>, 100, "only #{files.size} files scanned — the glob is too narrow"

    offenders = files.select { |f| Rails.root.join(f).read.include?(RETIRED_RECORD) }

    assert_empty offenders, <<~MSG
      These cite a file that no longer exists: #{offenders.join(', ')}

      The record lives in Kaneo now. Cite a specific issue as `tinkerex#N`, or point at
      CLAUDE.md §11 for a generic reference. §11 holds the base URL so the instance can move
      without touching any of these.
    MSG
  end

  # THE SAME SHAPE AS THE TEST ABOVE, IN THE DIRECTION THAT ACTUALLY SHIPPED. A comment citing a
  # dead path is a broken link; a comment citing a dead TEST is worse, because it does not READ as a
  # broken link — it reads as a SAFETY CLAIM. app/controllers/concerns/v1/authentication.rb said in
  # as many words that a parity test "compares the two implementations and fails when they stop
  # agreeing", naming two files Arc D Part 2 had already deleted (eaa180b, 448ba3b), while
  # CLAUDE.md §14j records that same cross-repo obligation as explicitly UNGUARDED. The comment and
  # the invariant contradicted each other and NOTHING COULD GO RED: no gate reads a comment, and a
  # guard that does not exist cannot fail. That is CLAUDE.md §15's "green suite over something that
  # never worked", with the green supplied by a sentence rather than by a test.
  #
  # SCOPED TO app/ + lib/ ON PURPOSE, AND WIDENING IT IS NOT FREE. config/routes.rb:204 and :304
  # cite two files that are gone — a mutation check "KEPT BECAUSE IT IS THE EVIDENCE AND IT IS NO
  # LONGER REPRODUCIBLE HERE", and the gem's own dummy-app routes — and BOTH are correct as written,
  # because both are past tense. Adding config/ therefore means adding an exemption list for them,
  # which is the shape §14e says goes stale. A historical NAME is not a dead link (the test above
  # makes the same carve-out for CLAUDE.md §11); what this catches is a citation written in the
  # PRESENT TENSE, and app/ + lib/ is where those live.
  CITATION_SCAN_DIRS = %w[app lib].freeze

  test "no source file cites a test file that does not exist" do
    files = CITATION_SCAN_DIRS.flat_map { |d| Dir.glob("#{d}/**/*.rb", base: Rails.root) }

    # TWO non-vacuity assertions, and neither implies the other (§14e). The first catches app/ or
    # lib/ moving away; the second catches the PATTERN being narrowed to nothing while every file is
    # still sitting there — a failure the first one cannot see.
    refute_empty files, "the scan found no source files at all — did the layout move? " \
                        "This test cannot guard a set it cannot find."
    assert_operator files.size, :>, 100, "only #{files.size} files scanned — the glob is too narrow"

    cited = files.flat_map { |f| Rails.root.join(f).read.scan(%r{\btest/[A-Za-z0-9_/.-]+\.rb\b}) }
                 .uniq.sort

    refute_empty cited, "no source file cites any test file — the pattern matched nothing. " \
                        "This test cannot guard a set it cannot find."

    missing = cited.reject { |c| Rails.root.join(c).file? }

    assert_empty missing, <<~MSG
      Code comments cite test files that do not exist: #{missing.join(', ')}

      A comment that names a test is read as a guarantee that something is CHECKED. Once the test is
      gone the guarantee is not merely stale, it is false, and no other gate in this repo can see it.
      Either restore the test, or rewrite the comment to say plainly that the thing is UNGUARDED —
      CLAUDE.md §14j is the worked example of the second answer.
    MSG
  end

  test "every docs/invariants file is cited by CLAUDE.md" do
    # Dir.glob, not Dir.children: a MISSING directory makes children raise ENOENT, which is loud but
    # reports a Ruby error rather than the argument below. glob answers [] instead, so the
    # refute_empty is what actually fires and says why it matters.
    files = Dir.glob("*.md", base: INVARIANTS_DIR).sort

    # Assert the scanned set first: a rename of docs/invariants/ would otherwise leave this test
    # asserting nothing at all, in perfect green health (§14e).
    refute_empty files, "docs/invariants/ holds no .md files — did the directory move? " \
                        "This test cannot guard a set it cannot find."

    claude = CLAUDE_MD.read
    orphans = files.reject { |f| claude.include?("docs/invariants/#{f}") }

    assert_empty orphans, <<~MSG
      docs/invariants/ files that CLAUDE.md never names: #{orphans.join(', ')}

      An invariants file nothing points at is never read. Add a stub under the relevant §14 anchor
      naming the PATHS that should send a reader to it — the stub is what makes the rules findable
      when they apply, and the whole split depends on it.
    MSG
  end

  test "every CLAUDE.md invariants pointer resolves to a real file" do
    cited = CLAUDE_MD.read.scan(%r{docs/invariants/([A-Za-z0-9_.-]+\.md)}).flatten.uniq.sort

    # Same reasoning as above, in the other direction: if the stubs were ever rewritten to stop
    # naming their files, this assertion would pass over an empty set and prove nothing.
    refute_empty cited, "CLAUDE.md names no docs/invariants/ file — the §14 stubs are gone or were " \
                        "rewritten. This test cannot guard a set it cannot find."

    missing = cited.reject { |f| INVARIANTS_DIR.join(f).file? }

    assert_empty missing, <<~MSG
      CLAUDE.md points at docs/invariants/ files that do not exist: #{missing.join(', ')}

      A pointer to nowhere is worse than a long file: the next agent reads it, finds nothing, and
      proceeds without the invariants it names — with nothing going red. Restore the file or fix the
      stub.
    MSG
  end

  test "the moved sections keep their anchors, because code cites them by number" do
    claude = CLAUDE_MD.read
    # EVERY SECTION THAT MOVED TO docs/invariants/, INCLUDING 14k AND 14l — 14k was omitted here
    # when the model catalog moved out, and 14l repeated the omission when git editing did, each
    # time leaving the anchor covered only by the two generic pointer tests and not by this one.
    # A list that is supposed to be exhaustive and silently is not is the same shape as a guard
    # scanning an empty set (§14e): it reports success over what it never checked. TWICE IS A
    # PATTERN, so the rule is now written down rather than left to be noticed a third time —
    # ADD THE ANCHOR HERE IN THE SAME COMMIT THAT CREATES THE STUB.
    moved = %w[14c 14f 14g 14h 14i 14k 14l 14m]

    moved.each do |anchor|
      assert_match(/^### #{anchor}\. /, claude,
                   "CLAUDE.md lost its §#{anchor} anchor. Code comments cite `§#{anchor}` by " \
                   "number (CLAUDE.md's own header measures the citation count); a section that " \
                   "MOVES keeps its anchor here as a stub so every existing citation still " \
                   "resolves. Do not renumber and do not delete the heading.")
    end
  end
end
