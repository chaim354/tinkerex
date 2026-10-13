require "test_helper"
require "support/gerber_fixture"

module Maker
  # WHAT A `.gbrjob` NAMES — `Maker::GerberSets.job_layer_names`, the `.gbrjob` reader behind a job
  # file's own page (FilesController#gerber_layers_for). Tested as a unit because it is one port
  # read plus a parse, and driving the file page to ask it would be slower and no more true; which
  # markup that page renders is test/integration/web/gerber_preview_test.rb's subject.
  #
  # SHARE IS PINNED BEFORE ANY NODE IS CREATED, because `job_layer_names` really opens the `.gbrjob`
  # through the port: a fixture with no bytes behind it would answer nil on every leg and the
  # positive cases would pass for the wrong reason.
  class GerberSetsTest < ActiveSupport::TestCase
    include GerberFixture

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "gerber-sets-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    teardown { FileLayer.reset! }

    def names_of(job) = Maker::GerberSets.job_layer_names(user: @user, node: job)

    test "a job names its layers by basename, as a Set" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl", "board.gbl", "board.drl"))

      assert_equal Set["board.gtl", "board.gbl", "board.drl"], names_of(job)
    end

    # `Path` CARRIES WHATEVER PREFIX THE EXPORTER FELT LIKE, and it is reduced to a BASENAME — never
    # resolved as a path, which could reach outside the folder or land on a name that repeats
    # elsewhere in the library. A backslash is not a path separator here: only the POSIX basename
    # resolves, so a Windows-style path yields the whole string and matches nothing.
    test "a job's Path is reduced to its POSIX basename, prefix and all" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: JSON.generate("FilesAttributes" => [
                                                { "Path" => "/home/someone/export/board.gtl" },
                                                { "Path" => "./board.drl" },
                                                { "Path" => "gerbers\\board.gbl" }
                                              ]))

      assert_equal Set["board.gtl", "board.drl", "gerbers\\board.gbl"], names_of(job)
    end

    # EVERY FAILURE MODE IS nil, which the caller turns into "every Gerber in the directory" — the
    # honest answer when nothing has told us otherwise, and the one that keeps a hand-made export
    # working.
    test "a malformed, non-object, attribute-less or empty job answers nil" do
      {
        "not json at all" => "{{{",
        "json that is not an object" => "[1, 2, 3]",
        "an object with no FilesAttributes" => JSON.generate("Header" => {}),
        "FilesAttributes with no usable Path" => JSON.generate("FilesAttributes" => [ { "Path" => "" }, 7 ]),
        "an empty FilesAttributes" => JSON.generate("FilesAttributes" => [])
      }.each do |why, body|
        dir = gerber_dir!(name: "pcb-#{SecureRandom.hex(3)}")
        job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id, body:)

        assert_nil names_of(job), why
      end
    end

    # THE SIZE CHECK IS ON THE CATALOG'S OWN COLUMN, so an oversized job costs no read at all —
    # Maker::Readme::READ_LIMIT makes the identical argument. Asserted through the row rather than
    # by writing half a megabyte of JSON, and the read count is what proves "never read".
    test "a job past READ_LIMIT is never read" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))
      job.update_column(:size, Maker::GerberSets::READ_LIMIT + 1)

      reads = []
      port = FileLayer.current
      original = port.method(:read)
      port.define_singleton_method(:read) { |user, **kw| reads << kw[:node_id]; original.call(user, **kw) }
      begin
        assert_nil names_of(job.reload)
      ensure
        port.singleton_class.remove_method(:read)
      end
      assert_empty reads, "an oversized job file was opened through the port"
    end

    # AN UNMOUNTED SHARE MUST NOT 500 THE PAGE. The port's two conditions are rescued beside
    # JSON::ParserError precisely so a job file whose bytes are unreachable still renders its page
    # from the directory — driven here by deleting the bytes under a row that still claims them.
    test "a job whose bytes are gone answers nil rather than raising" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))
      @root.join(job.storage_path).delete

      assert_nil names_of(job)
    end

    # AN OUTAGE IS SAID; A MISSING FILE IS NOT (F onboarding). Both answer nil, but only the store
    # not answering raises the layout's banner flag (app/models/current.rb). The port's `read` is
    # replaced to raise each condition in turn; Current is reset between them, as a request would be.
    test "an unreachable store answers nil and raises the banner flag; a missing job raises nothing" do
      dir = gerber_dir!(name: "pcb")
      job = write_gerber!(name: "board.gbrjob", parent_node_id: dir.node_id,
                          body: gerber_job("board.gtl"))

      answers = [ FileLayer::FetchError, FileLayer::NotFound ].to_h do |error|
        Current.reset
        port = FileLayer.current
        port.define_singleton_method(:read) { |_user, **_kw| raise error, "share not mounted" }
        begin
          assert_nil names_of(job), error.name
        ensure
          port.singleton_class.remove_method(:read)
        end
        [ error, Current.library_unreachable ]
      end

      assert answers[FileLayer::FetchError], "a FetchError did not raise the banner flag"
      assert_nil answers[FileLayer::NotFound], "a NotFound raised the banner flag; nothing is down"
    end
  end
end
