require "test_helper"

module Maker
  class ProjectDiscoveryTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pd-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @root = dir("d-projects", "Projects", nil)
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    test "an unclaimed folder becomes a project named verbatim and pointed at that folder" do
      dir("d-lamp", "Desk Lamp", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "Desk Lamp", project.name
      assert_equal "desk-lamp", project.slug
      assert_equal "d-lamp", project.folder_node_id
    end

    test "the run reports its own delta and the candidate count" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      dir("d-rack", "Rack", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 2, run.created
      assert_equal 2, run.candidates
      assert_equal :ok, run.status
    end

    # STEADY STATE REPORTS 0, not the number of projects the user has.
    test "a second sweep creates nothing" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      Maker::ProjectDiscovery.for_user(user: @user)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 1, @user.maker_projects.count
    end

    # TWO FOLDERS THAT SLUGIFY THE SAME BOTH ADOPT. `Projects/desk-lamp` (a project's own folder)
    # beside `Projects/Desk Lamp` (one made by hand) is the reachable case.
    test "colliding names both adopt, the second de-duped" do
      dir("d-a", "Desk Lamp", "d-projects")
      dir("d-b", "desk-lamp", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal %w[desk-lamp desk-lamp-2], @user.maker_projects.order(:slug).pluck(:slug)
    end

    test "a name with no latin characters adopts as project" do
      dir("d-jp", "プロジェクト", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "プロジェクト", project.name
      assert_equal "project", project.slug
    end

    # ARCHIVING IS THE DISMISSAL, AND THIS IS THE TEST THAT MAKES IT ONE. An archived project keeps
    # its folder_node_id, so the unscoped claim lookup passes over its folder forever.
    #
    # d-rack IS A POSITIVE CONTROL, AND IT MUST BE A DIFFERENT FOLDER FROM THE ARCHIVED ONE'S. A
    # bare "nothing changed" assertion cannot tell "the archived folder was correctly passed over"
    # from "the sweep is broken and adopted nothing at all" — see "dot-folders are skipped" for the
    # concrete mutation that stayed green under the old, absence-only version of this test. Asserting
    # the exact final folder set proves both halves at once: d-lamp was NOT re-adopted (it appears
    # once, not twice) and d-rack WAS (the sweep still works).
    test "an archived project still claims its folder" do
      folder = dir("d-lamp", "Desk Lamp", "d-projects")
      project = @user.maker_projects.create!(name: "Desk Lamp")
      project.update_column(:folder_node_id, folder.node_id)
      project.archive!
      dir("d-rack", "Rack", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 1, run.created
      assert_equal %w[d-lamp d-rack], @user.maker_projects.order(:folder_node_id).pluck(:folder_node_id)
    end

    # `.git` KEEPS ITS NODE (§14b) — it is the evidence a directory is a working tree — so without
    # the dot rule a repo checked out at the Projects/ root becomes a project titled ".git".
    #
    # d-lamp IS A POSITIVE CONTROL, NOT DECORATION. A bare `run.created == 0` is satisfied just as
    # happily by a sweep that correctly skips dot-folders as by one that is completely broken and
    # adopts NOTHING — concretely, `root.node_id` typo'd to `root.id` (the AR primary key, sitting
    # right on the same object) makes the candidate query match zero rows, ever, and this test
    # stayed green through that mutation before the sibling was added.
    #
    # `run.candidates == 1` IS A SECOND MEASUREMENT OF THE SAME FACT, NOT AN INDEPENDENT CHECK, and
    # is kept only because it reads clearly beside the set assertion. An earlier version of this
    # comment claimed it caught a different breakage than `created`; that was checked and is FALSE.
    # `created` counts `candidates.first(cap)`, and no fixture in this file comes near cap (50), so
    # `.first(cap)` never truncates and `created == candidates.size` always holds here — every
    # single-rule mutation moves both identically, and `created` fails first. Do not cite this
    # assertion as extra coverage; if you need cap math tested, that is the cap tests' job.
    test "dot-folders are skipped" do
      dir("d-git", ".git", "d-projects")
      dir("d-hidden", ".scratch", "d-projects")
      dir("d-lamp", "Desk Lamp", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 1, run.created
      assert_equal 1, run.candidates
      assert_equal [ "d-lamp" ], @user.maker_projects.pluck(:folder_node_id)
    end

    test "a folder deeper than a direct child is not adopted" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      dir("d-models", "models", lamp.node_id)

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal [ "d-lamp" ], @user.maker_projects.pluck(:folder_node_id)
    end

    # d-lamp IS A POSITIVE CONTROL — see "dot-folders are skipped" for why a bare `created == 0`
    # cannot tell "the file was correctly skipped" from "the sweep found nothing at all".
    test "a file directly under Projects is not adopted" do
      file("f-stray", "stray.stl", "d-projects")
      dir("d-lamp", "Desk Lamp", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 1, run.created
      assert_equal [ "d-lamp" ], @user.maker_projects.pluck(:folder_node_id)
    end

    # d-lamp IS A POSITIVE CONTROL — see "dot-folders are skipped" for why a bare `created == 0`
    # cannot tell "the tombstoned folder was correctly skipped" from "the sweep found nothing at
    # all".
    test "a tombstoned folder is not adopted" do
      dir("d-gone", "Gone", "d-projects").update!(deleted: true)
      dir("d-lamp", "Desk Lamp", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 1, run.created
      assert_equal [ "d-lamp" ], @user.maker_projects.pluck(:folder_node_id)
    end

    # NEVER MINTS `Projects/`. A user with no Projects folder is not swept — creating one as a side
    # effect of merely looking is Projects::AttachmentsController#relocate's recorded bug at
    # library-sweep scale.
    test "a library with no Projects folder creates nothing and mints nothing" do
      @user.nodes.destroy_all
      dir("d-other", "3D Models", nil)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal :no_projects_folder, run.status
      assert_equal 0, run.created
      assert_nil @user.nodes.present.find_by(name: "Projects", kind: "dir")
    end

    # THE PORT IS NEVER TOUCHED — no mkdir, no move, no bytes. That is what makes this sweep
    # identical on all three backends.
    test "the sweep creates no library nodes at all" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      before = @user.nodes.count

      # ASSERT THE SCANNED SET IS NON-EMPTY FIRST (§14e): "no nodes were created" is satisfied just
      # as happily by a sweep that found nothing to do, and that arm proves nothing.
      run = Maker::ProjectDiscovery.for_user(user: @user)
      assert_equal 1, run.created, "precondition: the sweep must actually have adopted something"

      assert_equal before, @user.nodes.count
    end

    # THE CREATION ORDER BELOW IS LOAD-BEARING — DO NOT ALPHABETIZE IT. The rows are inserted
    # `d-c, d-a, d-b`, deliberately NOT in node_id order, and that mismatch is the entire reason
    # this test can tell "explicitly sorted" from "happened to come back sorted". SQLite with no
    # ORDER BY returns rowid (insertion) order, so dropping `.order(:node_id)` from `adoptable`
    # makes `first(2)` pick {d-c, d-a} and this goes red — verified by mutation across five seeds.
    # Rewrite the fixture as `d-a, d-b, d-c` and the same mutation passes: insertion order would
    # then coincide with the sorted answer, and the guard would silently stop guarding.
    test "a run over the cap adopts deterministically and says it was capped" do
      dir("d-c", "Gamma", "d-projects")
      dir("d-a", "Alpha", "d-projects")
      dir("d-b", "Beta", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user, cap: 2)

      assert_equal :capped, run.status
      assert_equal 2, run.created
      assert_equal 3, run.candidates
      # ORDERED BY node_id, so a second run continues where this one stopped rather than
      # re-rolling the dice.
      assert_equal %w[d-a d-b], @user.maker_projects.order(:folder_node_id).pluck(:folder_node_id)
    end

    test "the next run continues where a capped run stopped" do
      dir("d-a", "Alpha", "d-projects")
      dir("d-b", "Beta", "d-projects")
      Maker::ProjectDiscovery.for_user(user: @user, cap: 1)

      run = Maker::ProjectDiscovery.for_user(user: @user, cap: 1)

      assert_equal :ok, run.status
      assert_equal %w[d-a d-b], @user.maker_projects.order(:folder_node_id).pluck(:folder_node_id)
    end

    # `Integer("-5")` SUCCEEDS, so a rescue never sees a negative — it reaches `first(-5)` and
    # raises "negative array size" from inside a recurring job, far from the typo.
    test "a nonsense cap override falls back instead of crashing" do
      dir("d-lamp", "Desk Lamp", "d-projects")

      ENV["PROJECT_DISCOVERY_MAX"] = "-5"
      assert_equal Maker::ProjectDiscovery::MAX_PROJECTS, Maker::ProjectDiscovery.max_projects
      assert_nothing_raised { Maker::ProjectDiscovery.for_user(user: @user) }

      ENV["PROJECT_DISCOVERY_MAX"] = "0"
      assert_equal Maker::ProjectDiscovery::MAX_PROJECTS, Maker::ProjectDiscovery.max_projects

      ENV["PROJECT_DISCOVERY_MAX"] = "banana"
      assert_equal Maker::ProjectDiscovery::MAX_PROJECTS, Maker::ProjectDiscovery.max_projects
    ensure
      ENV.delete("PROJECT_DISCOVERY_MAX")
    end

    test "a valid cap override is honoured" do
      ENV["PROJECT_DISCOVERY_MAX"] = "7"

      assert_equal 7, Maker::ProjectDiscovery.max_projects
    ensure
      ENV.delete("PROJECT_DISCOVERY_MAX")
    end

    # THE OVERRIDE MUST REACH A REAL SWEEP, AND ASSERTING `max_projects` ALONE DOES NOT SHOW THAT.
    # Demonstrated, not theorized: mutating `for_user`'s `cap ||= max_projects` to
    # `cap ||= MAX_PROJECTS` — hardcoding the constant and ignoring ENV entirely — left every other
    # test in this file GREEN. The two cap tests above pass `cap:` explicitly, so they never
    # exercise default resolution at all, and the nonsense-override values (-5, 0, "banana") all
    # fall back to the very constant the mutation hardcodes, so they cannot tell "reads the knob"
    # from "ignores the knob". `PROJECT_DISCOVERY_MAX` is an operator-facing knob named in
    # docs/DEPLOY-adjacent prose and in `rake projects:discover`'s own description; it could have
    # been inert in production with a fully green suite.
    #
    # SO THIS TEST PASSES NO `cap:`. That omission is the whole point — do not "clarify" it by
    # adding one.
    test "a valid cap override bounds a real sweep" do
      ENV["PROJECT_DISCOVERY_MAX"] = "1"
      dir("d-a", "Alpha", "d-projects")
      dir("d-b", "Beta", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal :capped, run.status
      assert_equal 1, run.created
      assert_equal 2, run.candidates
      assert_equal [ "d-a" ], @user.maker_projects.pluck(:folder_node_id)
    ensure
      ENV.delete("PROJECT_DISCOVERY_MAX")
    end

    # STORY 1.1 — "zero feedback: no flash, no 'new' marker". The marker is a column, and it is
    # written by THIS sweep and by nothing else, which is what lets a page read `discovered_at`
    # as "the app made this, I did not".
    test "a discovered project is stamped, and the whole run shares one moment" do
      dir("d-lamp", "Desk Lamp", @root.node_id)
      dir("d-tray", "Tray", @root.node_id)

      Maker::ProjectDiscovery.for_user(user: @user)

      stamps = @user.maker_projects.order(:name).pluck(:discovered_at)
      assert_equal 2, stamps.compact.size, "every row this sweep created carries the mark"
      assert_equal 1, stamps.uniq.size, "one run is one moment, not one moment per row"
    end

    # A hand-made project must NOT wear the badge, or the badge means nothing. Asserted here
    # rather than only in the web suite because the column's meaning is this class's to keep.
    test "a project created any other way is not stamped" do
      assert_nil @user.maker_projects.create!(name: "By Hand", slug: "by-hand").discovered_at
    end

    # THE RUN NAMES WHAT IT MADE, so a door with a user in front of it can say more than a count.
    # `names` follows the same DETERMINISTIC order `candidates` does (ORDER BY node_id), which is
    # what makes a capped run reproducible — see #adoptable.
    test "the run reports the names it created, in the order it created them" do
      dir("d-b", "Beta", @root.node_id)
      dir("d-a", "Alpha", @root.node_id)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal %w[Alpha Beta], run.names
      assert_equal 2, run.created
    end

    test "a run that creates nothing names nothing, and a run with nowhere to look does too" do
      assert_equal [], Maker::ProjectDiscovery.for_user(user: @user).names
      @root.update!(deleted: true)
      run = Maker::ProjectDiscovery.for_user(user: @user)
      assert_equal :no_projects_folder, run.status
      assert_equal [], run.names, "a Result built without names reads as none, never nil"
    end

    # ONE NAME RULE, TWO DOORS. Projects::AdoptionsController must refuse the names this sweep
    # refuses, or the two doors disagree about what a project folder may be called — and a `.git`
    # folder adopted by hand is a project literally titled ".git", the exact case #adoptable's own
    # dot rule exists to stop.
    test "the name rule is public, and it is the one the sweep itself applies" do
      assert Maker::ProjectDiscovery.adoptable_name?("Desk Lamp")
      refute Maker::ProjectDiscovery.adoptable_name?(".git")
      refute Maker::ProjectDiscovery.adoptable_name?(".hidden")
      refute Maker::ProjectDiscovery.adoptable_name?(nil)
    end

    # STAGE 4, S4-7 (decision D4): the sweep names what it adopted. A discovered folder is the ONE
    # case where the app has files in front of it at creation time, so it is where a kind can be
    # suggested at all — the web form mints an empty folder and has nothing to read.
    test "a discovered folder is created with the kind its files suggest" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      %w[box.lbrn2 lid.lbrn panel.svg tray.dxf].each_with_index { |n, i| file("f-#{i}", n, lamp.node_id) }

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal "laser", @user.maker_projects.sole.kind
    end

    # THE DEFAULT IS STILL THE DEFAULT. A folder with nothing recognisable in it must not be
    # guessed at, and `other`'s preset is today's page (spec §4).
    test "a folder with nothing to read is created as other" do
      dir("d-empty", "Empty", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal "other", @user.maker_projects.sole.kind
    end

    # ONE WRITE, NEVER A CREATE-THEN-UPDATE: a project is never momentarily `other`, so nothing
    # that watches maker_projects (the eager intake chain, a device push) can observe a kind that
    # was never true. Asserted on the row's own updated_at against its created_at rather than by
    # counting statements, which no public API here exposes.
    test "the kind is part of the create, not an update after it" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      %w[base.stl body.step].each_with_index { |n, i| file("f-#{i}", n, lamp.node_id) }

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "print", project.kind
      assert_equal project.created_at, project.updated_at
    end

    # THE SWEEP STILL TOUCHES NO PORT (the class's own header claim). The suggestion reads `nodes`,
    # which every backend populates — so this test passes identically on the three legs and needs
    # no library on disk. Driven, not reasoned: FileLayer.current is never constructed here.
    test "the suggestion reads the catalog and nothing else" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      file("f-0", "main.c", lamp.node_id)
      file("f-1", "board.gtl", lamp.node_id)

      assert_equal "electronics", Maker::ProjectKind.suggest_for(user: @user, folder_node_id: lamp.node_id)
    end
  end
end
