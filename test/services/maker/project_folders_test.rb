require "test_helper"

module Maker
  # The folder map, and above all its TOTALITY -- split two ways since stage 3, S3-1.
  # ROLE_FOLDERS must still map EVERY role (that totality is what the SEED needs:
  # Maker::FilingRules.seed! builds one row per ROLE_BY_EXT extension via ROLE_FOLDERS.fetch(role),
  # no default, so a gap here becomes a loud KeyError the first time any user's map is seeded).
  # `folder_for(user, name)` itself is deliberately NOT total over extensions any more -- an
  # unmapped one now files into "other" as a per-user, expected answer (see
  # app/services/maker/project_folders.rb's header for why that is not the same rejected shape).
  class ProjectFoldersTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "project-folders-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # THE GUARD THIS FILE EXISTS FOR. `default_folder_for` uses `fetch` with no default: reached
    # with an unmapped role, it raises KeyError — LOUD, not silent. What makes this test necessary
    # is that the raise is normally UNREACHABLE: role_for only returns a role once some extension
    # is wired to it in ROLE_BY_EXT, so a role added to ROLES without a folder decision can sit
    # here completely unexercised, with nothing to notice, until `Maker::FilingRules.seed!`
    # finally reaches the fetch for some user's first visit and the raise becomes a production
    # incident. This test is what catches the gap first. (The rejected `fetch(role, "other")`
    # default is the genuinely silent failure — it would misfile instead of raising.)
    # Mutation-check it by deleting a key from ROLE_FOLDERS.
    test "every role has a folder" do
      assert_equal Maker::FileAttachment::ROLES.to_set,
                   Maker::ProjectFolders::ROLE_FOLDERS.keys.to_set,
                   "add the new role to ROLE_FOLDERS — a role with no folder is never seeded"
    end

    # THE STATIC, ROLE-KEYED VOCABULARY -- default_folder_for is what the seed itself is built
    # from, so this still pins the category decisions directly rather than through a seeded user.
    test "the categories the folders were named for" do
      assert_equal "cnc",      Maker::ProjectFolders.default_folder_for("pocket.nc")
      assert_equal "cnc",      Maker::ProjectFolders.default_folder_for("roughing.gcode")
      assert_equal "laser",    Maker::ProjectFolders.default_folder_for("box.lbrn2")
      assert_equal "design",   Maker::ProjectFolders.default_folder_for("panel.svg")
      assert_equal "design",   Maker::ProjectFolders.default_folder_for("panel.dxf")
      assert_equal "models",   Maker::ProjectFolders.default_folder_for("bracket.stl")
      assert_equal "cad",      Maker::ProjectFolders.default_folder_for("body.f3d")
      assert_equal "docs",     Maker::ProjectFolders.default_folder_for("guide.pdf")
      assert_equal "docs",     Maker::ProjectFolders.default_folder_for("notes.md")
      assert_equal "images",   Maker::ProjectFolders.default_folder_for("photo.jpg")
      assert_equal "archives", Maker::ProjectFolders.default_folder_for("printables.zip")
      assert_equal "code",     Maker::ProjectFolders.default_folder_for("main.cpp")
      assert_equal "pcb",      Maker::ProjectFolders.default_folder_for("board.gtl")
      assert_equal "pcb",      Maker::ProjectFolders.default_folder_for("board.drl")
      assert_equal "cnc",      Maker::ProjectFolders.default_folder_for("catan.mage")
      assert_equal "laser",    Maker::ProjectFolders.default_folder_for("tray.lbrn")
      assert_equal "design",   Maker::ProjectFolders.default_folder_for("logo.ai")
    end

    # TWO ROLES, ONE FOLDER — the `docs` shape, pinned so a later "tidy-up" that gives cnc_design
    # its own directory has to argue with a test instead of with a hash.
    test "the MillMage project and its g-code output share the cnc folder and not the role" do
      assert_equal Maker::ProjectFolders.default_folder_for("catan.mage"),
                   Maker::ProjectFolders.default_folder_for("catan.nc")
      assert_equal "cnc_design", Maker::FileAttachment.role_for("catan.mage")
      assert_equal "gcode",      Maker::FileAttachment.role_for("catan.nc")
    end

    # THE ARGUABLE HALF OF THE `pcb` ROLE, pinned separately for the reason the `code` block below
    # is: a `.gbrjob` is JSON and a `.drl` is a drill program, so `docs` and `cnc` were both real
    # alternatives. They file with the layers because a board house is handed ONE directory, and
    # splitting a fabrication package across three folders is what this rules out.
    test "the drill file and the job manifest file with the board, not with the CNC or the docs" do
      assert_equal "pcb", Maker::ProjectFolders.default_folder_for("board.drl")
      assert_equal "pcb", Maker::ProjectFolders.default_folder_for("board.xln")
      assert_equal "pcb", Maker::ProjectFolders.default_folder_for("board.gbrjob")
      assert_equal "cnc", Maker::ProjectFolders.default_folder_for("pocket.nc")
    end

    # THE PER-USER MAP CARRIES THE NEW ROLE TOO — a seeded user files a loose `.gtl` into `pcb/`,
    # which is what the intake sweep actually reads (the role table alone would not prove it).
    test "a newly seeded user files a Gerber into pcb" do
      assert_equal "pcb", Maker::ProjectFolders.folder_for(@user, "board.gtl")
      assert_equal "pcb", Maker::ProjectFolders.folder_for(@user, "BOARD.GTL")
      assert_equal "pcb", Maker::ProjectFolders.folder_for(@user, "board.gbrjob")
    end

    # THE ARGUABLE HALF OF THE `code` ROLE, pinned separately from the roll-call above because it
    # is the decision someone would reverse: a build/config file lands beside the code it
    # configures, not in `docs` with the READMEs. `docs` is where `document` and `instructions`
    # both go, so the alternative was real and this is what rules it out.
    test "build and config files file with the code, not with the documents" do
      assert_equal "code", Maker::ProjectFolders.default_folder_for("platformio.ini")
      assert_equal "code", Maker::ProjectFolders.default_folder_for("Cargo.toml")
      assert_equal "docs", Maker::ProjectFolders.default_folder_for("README.md")
    end

    # An unrecognised extension must land somewhere rather than raise: role_for defaults to
    # "other", so this is really asserting the two defaults agree.
    test "an unknown extension goes to other, by default_folder_for's role-based fallback" do
      assert_equal "other", Maker::ProjectFolders.default_folder_for("mystery.qqq")
      assert_equal "other", Maker::ProjectFolders.default_folder_for("README")
    end

    # STAGE 3, S3-1: THE PER-USER LOOKUP READS THE SEEDED (OR EDITED) MAP, CASE-INSENSITIVELY.
    test "folder_for(user, name) reads the user's own seeded rule" do
      assert_equal "models", Maker::ProjectFolders.folder_for(@user, "bracket.stl")
      assert_equal "models", Maker::ProjectFolders.folder_for(@user, "bracket.STL")
      assert_equal "docs",   Maker::ProjectFolders.folder_for(@user, "README.md")
    end

    # THE TOTALITY GUARD'S NEW HALF (spec §5): "an unmapped role raises" becomes "an unmapped
    # extension files into other" — folder_for(user, name) is total over the user's OWN rows, not
    # over every conceivable extension, and "other" is the honest per-user answer for one nobody
    # has an opinion on (see the class comment for why this is not the rejected `fetch(role,
    # "other")` shape default_folder_for's own totality test still guards against).
    test "folder_for(user, name) files an extension with no rule into other" do
      assert_equal "other", Maker::ProjectFolders.folder_for(@user, "mystery.qqq")
      assert_equal "other", Maker::ProjectFolders.folder_for(@user, "README")
    end

    # The names are lowercase because they appear in Finder and on the NAS — deliberately NOT
    # ROLE_LABELS ("G-code", "CAD source"), which are UI headings. STAGE 3, S3-1 ADDS THE SECOND
    # HALF: every (ext, folder) pair Maker::FilingRules.seed! would actually WRITE must itself pass
    # Maker::FilingRule's own validation, so the seed can never produce a row the /settings/filing
    # form would refuse if a user tried to type it back in.
    test "folder names are single lowercase path segments, and every seed folder passes FilingRule's own validation" do
      Maker::ProjectFolders::ROLE_FOLDERS.values.uniq.each do |name|
        assert_match(/\A[a-z0-9]+\z/, name, name)
      end

      Maker::FileAttachment::ROLE_BY_EXT.each do |ext, role|
        folder = Maker::ProjectFolders::ROLE_FOLDERS.fetch(role)
        rule = @user.maker_filing_rules.new(ext:, folder:)
        assert rule.valid?,
               "the seed would write #{ext.inspect} -> #{folder.inspect}, which FilingRule " \
               "itself refuses: #{rule.errors.full_messages.join(', ')}"
      end
    end

    # THE LITERAL MUST NOT REAPPEAR. ROOT exists because "Projects" was spelled out in two files and
    # a third was about to add it. A constant nothing enforces is a convention, and this repo's
    # recorded drift (FilesHelper::EXT_FAMILIES vs ROLE_BY_EXT — two lists that disagreed about .svg
    # for months) is what a convention buys you.
    #
    # Mutation-check, both directions: put a bare `"Projects"` back into any file below AS CODE and
    # this goes RED; put `"Projects"` into a COMMENT in one of those files and this must stay GREEN.
    test "no maker file spells the Projects root as a bare literal" do
      files = %w[
        app/models/maker/project.rb
        app/services/maker/project_intake.rb
        app/services/maker/project_discovery.rb
      ].map { |f| Rails.root.join(f) }.select(&:exist?)

      # ASSERT THE SCANNED SET FIRST (§14e). Two architecture guards in this repo went on passing
      # over an empty glob once the directory they scanned moved away; a path-keyed guard can be
      # silently retired by a rename. THIS CATCHES TOTAL LOSS ONLY: if one of the three files were
      # renamed while its siblings survived, `files` would silently shrink by one and that file
      # would drop out of coverage with nothing here to notice — the partial-loss version of the
      # same shape. An exact-count assertion would close that gap but isn't viable yet:
      # project_discovery.rb doesn't exist until Task 4, so there is no fixed count to assert
      # against until all three files do.
      refute_empty files, "none of the maker files this guards exist — did they move?"

      # code_lines, NOT a raw f.read substring scan — a plain substring match hits "Projects"
      # inside an ordinary WHY-comment too, and this codebase's own mandated comment style is
      # exactly the dense narrative kind likely to quote a folder name in passing
      # (project_discovery.rb, arriving in Task 4, will be written the same way). Demonstrated,
      # not theorized: adding one ordinary comment to project.rb that only POINTS AT this constant
      # ("...see ProjectFolders::ROOT") turned this test red with no literal reintroduced anywhere.
      # That is the same bug shape CLAUDE.md §14d already paid for — the Sync:: seam guard is
      # Ripper-token-checked rather than a regex, because a regex false-positives on prose naming
      # "Sync::Gc" in an error string with zero real references. test/ci_hygiene_test.rb's
      # code_lines strips whole-line comments for the identical reason; this reuses that technique
      # rather than inventing a second one. A whole-line strip is enough here — the value is a
      # plain path segment, not a constant reference, so a trailing comment after real code is not
      # a plausible false positive worth Ripper tokenization to rule out.
      offenders = files.select { |f| code_lines(f).any? { |l| l.include?('"Projects"') } }
                       .map { |f| f.relative_path_from(Rails.root).to_s }

      assert_empty offenders, "spell it Maker::ProjectFolders::ROOT, not a bare \"Projects\""
    end

    private

      # Source lines with blanks and whole-line comments removed — same technique as
      # test/ci_hygiene_test.rb's helper of the same name, kept for the same reason: a raw
      # substring scan cannot tell code from prose that happens to quote the same string.
      def code_lines(path)
        path.readlines(chomp: true).reject { |l| l.strip.empty? || l.strip.start_with?("#") }
      end
  end
end
