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
  MAX_LINES = 1_350

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

      The record lives in Forgejo now. Cite a specific issue as `tinkerex#N`, or point at
      CLAUDE.md §11 for a generic reference. §11 holds the base URL so the instance can move
      without touching any of these.
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
    # EVERY SECTION THAT MOVED TO docs/invariants/, INCLUDING 14k — it was omitted here when the
    # model catalog moved out, so its anchor was covered only by the two generic pointer tests and
    # not by this one. A list that is supposed to be exhaustive and silently is not is the same
    # shape as a guard scanning an empty set (§14e): it reports success over what it never checked.
    moved = %w[14c 14f 14g 14h 14i 14k]

    moved.each do |anchor|
      assert_match(/^### #{anchor}\. /, claude,
                   "CLAUDE.md lost its §#{anchor} anchor. Code comments cite `§#{anchor}` by " \
                   "number (CLAUDE.md's own header measures the citation count); a section that " \
                   "MOVES keeps its anchor here as a stub so every existing citation still " \
                   "resolves. Do not renumber and do not delete the heading.")
    end
  end
end
