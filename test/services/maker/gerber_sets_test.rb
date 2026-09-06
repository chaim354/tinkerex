require "test_helper"
require "support/gerber_fixture"

module Maker
  # WHAT COUNTS AS ONE BOARD — the grouping both Fabrication panels read, tested here as a unit
  # because it is a pure function of rows plus (for a `.gbrjob`) one port read, and driving two web
  # pages to ask it would be slower and no more true. The panels' own markup is
  # test/integration/web/gerber_preview_test.rb's subject.
  #
  # SHARE IS PINNED BEFORE ANY NODE IS CREATED, because `job_layer_names` really opens the `.gbrjob`
  # through the port: a fixture with no bytes behind it would take the fallback branch on every leg
  # and the job tests would pass for the wrong reason.
  class GerberSetsTest < ActiveSupport::TestCase
    include GerberFixture

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "gerber-sets-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    teardown { FileLayer.reset! }

    # The listing's own Row shape, built here from nodes rather than by running a real
    # ProjectFolderListing: this service takes rows and knows nothing about how they were gathered.
    def rows_for(*nodes, section: "")
      nodes.map { |node| Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: false, section:) }
    end

    def boards_for(*nodes, section: "")
      Maker::GerberSets.for(user: @user, rows: rows_for(*nodes, section:))
    end

    test "a folder of Gerbers is one board, name-ordered, with the folder's name" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)

      boards = boards_for(*set.values, section: "pcb")

      assert_equal 1, boards.size
      assert_equal "pcb", boards.first.name
      assert_equal %w[board.drl board.gbl board.gtl], boards.first.rows.map { |r| r.node.name }
      assert_equal %w[board.drl board.gbl board.gtl], boards.first.stacked.map { |r| r.node.name }
    end

    # NON-GERBER ROWS ARE NOT A BOARD'S BUSINESS. The panel is handed the WHOLE folder listing, so
    # this filter is what stops a README turning up in a stackup.
    test "rows that are not Gerbers are ignored entirely" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      other = write_gerber!(name: "notes.txt", parent_node_id: dir.node_id, body: "hello")

      boards = boards_for(*set.values, other, section: "pcb")

      assert_equal %w[board.drl board.gbl board.gtl], boards.first.rows.map { |r| r.node.name }
    end

    test "no Gerbers at all is no boards" do
      node = write_gerber!(name: "notes.txt", body: "hello")

      assert_empty boards_for(node)
    end

    # THE GROUPING KEY IS THE PARENT DIRECTORY. A project holds a main board and a daughterboard;
    # stacking both folders' copper together would render an image of nothing real.
    test "two directories are two boards" do
      main = gerber_dir!(name: "main")
      aux = gerber_dir!(name: "aux")
      a = write_gerber_set!(stem: "main", parent_node_id: main.node_id)
      b = write_gerber_set!(stem: "aux", parent_node_id: aux.node_id)

      boards = Maker::GerberSets.for(user: @user,
                                     rows: rows_for(*a.values, section: "main") +
                                           rows_for(*b.values, section: "aux"))

      assert_equal 2, boards.size
      assert_equal %w[aux main], boards.map(&:name)
      assert_equal [ 3, 3 ], boards.map { |board| board.stacked.size }
    end

    # THE FOLDER'S OWN ROOT SORTS FIRST and has no directory name to borrow.
    test "a set loose at the folder root is a board called Board, and comes first" do
      loose = write_gerber_set!(stem: "loose")
      dir = gerber_dir!(name: "pcb")
      nested = write_gerber_set!(parent_node_id: dir.node_id)

      boards = Maker::GerberSets.for(user: @user,
                                     rows: rows_for(*nested.values, section: "pcb") +
                                           rows_for(*loose.values, section: ""))

      assert_equal %w[Board pcb], boards.map(&:name)
    end

    # --- the .gbrjob ------------------------------------------------------------

    # THE LIST AND THE STACK ARE DIFFERENT LISTS. A stray layer from an old revision is LISTED so it
    # does not go invisible, and left out of the render because the manifest did not name it.
    test "a job file's list decides what is stacked; everything is still listed" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      stray = write_gerber!(name: "old-revision.gtl", parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl", "board.gbl", "board.drl"))

      board = boards_for(*set.values, stray, job, section: "pcb").first

      assert_equal 5, board.rows.size
      assert_equal %w[board.drl board.gbl board.gtl], board.stacked.map { |r| r.node.name }
      assert_equal "board", board.name, "a job file's stem names the board"
    end

    # ONLY THE FIRST JOB THAT ANSWERS IS READ. Each job read is a port call a public page triggers
    # anonymously, so a folder holding several job files must not pay for all of them when the
    # first names the set — the review measured the eager form reading every one.
    test "with several job files only the first usable one is read through the port" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      first = write_gerber!(name: "a-board.gbrjob", parent_node_id: dir.node_id,
                            body: gerber_job("board.gtl", "board.gbl", "board.drl"))
      second = write_gerber!(name: "b-board.gbrjob", parent_node_id: dir.node_id,
                             body: gerber_job("board.gtl"))

      adapter = FileLayer.current
      original = adapter.method(:read)
      reads = []
      adapter.define_singleton_method(:read) { |user, **kw| reads << kw[:node_id]; original.call(user, **kw) }
      begin
        board = boards_for(*set.values, first, second, section: "pcb").first
      ensure
        adapter.singleton_class.remove_method(:read)
      end

      assert_equal [ first.node_id ], reads, "the second job was read although the first named the set"
      assert_equal %w[board.drl board.gbl board.gtl], board.stacked.map { |r| r.node.name }
    end

    # THE MANIFEST IS NEVER ITSELF STACKED — tracespace's Gerber parser turns JSON into a junk layer
    # rather than raising, so nothing else would report this going wrong.
    test "a job file is never one of its own layers, even when it names itself" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl", "board.gbrjob"))

      board = boards_for(*set.values, job, section: "pcb").first

      assert_equal %w[board.gtl], board.stacked.map { |r| r.node.name }
    end

    # `Path` CARRIES WHATEVER PREFIX THE EXPORTER FELT LIKE (the fixture writes "./name"), and it is
    # matched by BASENAME against the rows already in hand — never resolved as a path, which could
    # reach outside the folder or land on a name that repeats elsewhere in the library.
    test "a job's Path is matched by basename, prefix and all" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: JSON.generate("FilesAttributes" => [
                                                { "Path" => "/home/someone/export/board.gtl" },
                                                { "Path" => "gerbers\\board.gbl" }
                                              ]))

      board = boards_for(*set.values, job, section: "pcb").first

      assert_equal %w[board.gtl], board.stacked.map { |r| r.node.name },
                   "a backslash is not a path separator here; only the POSIX basename resolves"
    end

    # EVERY FAILURE MODE FALLS BACK TO THE DIRECTORY, which is the honest answer when nothing has
    # told us otherwise — and the one that keeps a hand-made export working.
    test "a malformed, empty, oversized or unreadable job falls back to the whole directory" do
      names = %w[board.drl board.gbl board.gtl]
      {
        "not json at all" => "{{{",
        "json that is not an object" => "[1, 2, 3]",
        "an object with no FilesAttributes" => JSON.generate("Header" => {}),
        "FilesAttributes naming nothing this folder holds" => gerber_job("elsewhere.gtl")
      }.each do |why, body|
        dir = gerber_dir!(name: "pcb-#{SecureRandom.hex(3)}")
        set = write_gerber_set!(parent_node_id: dir.node_id)
        job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id, body:)

        board = boards_for(*set.values, job, section: "pcb").first

        assert_equal names, board.stacked.map { |r| r.node.name }, why
      end
    end

    # THE SIZE CHECK IS ON THE CATALOG'S OWN COLUMN, so an oversized job costs no read at all —
    # Maker::Readme::READ_LIMIT makes the identical argument. Asserted through the row rather than
    # by writing half a megabyte of JSON.
    test "a job past READ_LIMIT is never read" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))
      job.update_column(:size, Maker::GerberSets::READ_LIMIT + 1)

      board = boards_for(*set.values, job, section: "pcb").first

      assert_equal %w[board.drl board.gbl board.gtl], board.stacked.map { |r| r.node.name }
    end

    # AN UNMOUNTED SHARE MUST NOT 500 THE PAGE. `job_layer_names` rescues the port's two conditions
    # beside JSON::ParserError precisely so a folder whose bytes are unreachable still renders its
    # file list — driven here by deleting the bytes under a row that still claims them.
    test "a job whose bytes are gone falls back rather than raising" do
      dir = gerber_dir!(name: "pcb")
      set = write_gerber_set!(parent_node_id: dir.node_id)
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))
      @root.join(job.storage_path).delete

      board = boards_for(*set.values, job, section: "pcb").first

      assert_equal %w[board.drl board.gbl board.gtl], board.stacked.map { |r| r.node.name }
    end

    # A JOB ALONE IS STILL A BOARD ROW (so the panel lists it), with nothing to stack.
    test "a job file with no layers beside it lists itself and stacks nothing" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))

      board = boards_for(job, section: "pcb").first

      assert_equal %w[board.gbrjob], board.rows.map { |r| r.node.name }
      assert_empty board.stacked
    end
  end
end
