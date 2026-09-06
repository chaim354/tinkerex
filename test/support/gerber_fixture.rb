# REAL, MINIMAL Gerber and Excellon bytes tracespace can actually parse — shared between
# test/system/gerber_test.rb (which asserts the viewer renders in a live browser),
# test/integration/web/gerber_preview_test.rb (which needs a `.gbrjob` the SERVER really reads) and
# test/system/shell_test.rb's phone-width sweep (which needs the Fabrication panel's real markup on
# the page at 375px, and needs tracespace not to error on garbage bytes and trip
# assert_no_console_errors for a reason that has nothing to do with layout).
#
# test/system/README.md's house rule for the system suite, and the reason this file exists at all
# rather than reusing test_helper's `create_node!`: that helper always materialises a literal "x"
# placeholder for a file node (deliberately — most fixtures never read the bytes back), which
# tracespace would receive as an unparseable layer. test/support/kicad_fixture.rb is the same
# shape for the same reason and this deliberately mirrors it.
module GerberFixture
  # ONE RS-274X LAYER DRAWING A 10 mm SQUARE, which is the smallest thing that produces a real
  # `<path>` rather than an empty render. Probed against the vendored bundle, not guessed:
  #
  #   %FSLAX24Y24*%  format — leading zeros omitted, absolute, 2 integer + 4 decimal digits, so the
  #                  coordinate 100000 is 10.0000
  #   %MOMM*%        units are millimetres
  #   %ADD10C,0.5*%  aperture D10 is a 0.5 mm circle
  #   D02 / D01      move without drawing / draw — four D01s close the square
  #   M02*           end of file
  #
  # AN APERTURE AND AT LEAST ONE D01 ARE BOTH REQUIRED. A file with only D02 moves plots nothing,
  # renders an empty <svg>, and would make the system test's "holds a path" assertion fail for a
  # reason that has nothing to do with the viewer working.
  MINIMAL_GERBER = <<~GERBER
    %FSLAX24Y24*%
    %MOMM*%
    %ADD10C,0.5*%
    D10*
    X0Y0D02*
    X100000Y0D01*
    X100000Y100000D01*
    X0Y100000D01*
    X0Y0D01*
    M02*
  GERBER

  # A MINIMAL EXCELLON DRILL FILE: one 0.8 mm tool, one hit at (10, 10).
  #
  # IT RENDERS A `<circle>`, NOT A `<path>` — measured against the vendored bundle. That is why the
  # system test asserts its path on a `.gtl` and never on a drill file: an assertion written for
  # "any Gerber renders a path" would be red on this input while the viewer worked perfectly.
  MINIMAL_DRILL = <<~DRILL
    M48
    METRIC
    T1C0.800
    %
    T1
    X10.0Y10.0
    M30
  DRILL

  # A GERBER JOB FILE naming a subset of the layers beside it. `FilesAttributes[].Path` is the only
  # key `Maker::GerberSets` reads; the rest is what a real KiCad export writes around it, kept so
  # the fixture is a job file rather than a hash with one key in it.
  #
  # THE `./` PREFIX IS DELIBERATE AND IS PART OF WHAT THIS FIXTURE TESTS: real exporters write any
  # prefix they like, and `GerberSets` matches on `File.basename` for exactly that reason. A bare
  # name here would let a path-resolving implementation pass.
  def gerber_job(*names)
    JSON.generate(
      "Header" => { "GenerationSoftware" => { "Vendor" => "tinkerex", "Application" => "test" } },
      "GeneralSpecs" => { "ProjectId" => { "Name" => "board" }, "Size" => { "X" => 10, "Y" => 10 } },
      "FilesAttributes" => names.map { |name| { "Path" => "./#{name}", "FileFunction" => "Other" } }
    )
  end

  # A REAL FILE ON DISK with the node row's content_hash matching it — kicad_fixture.rb's
  # `write_kicad_schematic!` exactly, and for the identical reason its own comment gives:
  # `nodes.create!`, NOT test_helper's `create_node!`, which would overwrite these bytes with its
  # "x" placeholder the moment the row was made.
  def write_gerber!(name:, parent_node_id: nil, body: MINIMAL_GERBER)
    parent = parent_node_id && @user.nodes.find_by(node_id: parent_node_id)
    rel = parent&.storage_path.present? ? File.join(parent.storage_path, name) : name
    path = @root.join(rel)
    path.dirname.mkpath
    path.binwrite(body)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id:,
                        size: body.bytesize, storage_path: rel, mtime: 1_000_000_000,
                        content_hash: Digest::SHA256.hexdigest(body))
  end

  # A DIRECTORY WITH A REAL storage_path, so `write_gerber!` above can place files inside it — the
  # `parent&.storage_path.present?` branch is what needs this, and a dir row made with a NULL
  # storage_path would silently put every "child" at the library root instead, where they would all
  # group into ONE board and the grouping tests would pass for the wrong reason.
  def gerber_dir!(name:, parent_node_id: nil)
    parent = parent_node_id && @user.nodes.find_by(node_id: parent_node_id)
    rel = parent&.storage_path.present? ? File.join(parent.storage_path, name) : name
    @root.join(rel).mkpath
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id:,
                        size: 0, storage_path: rel, mtime: 1_000_000_000)
  end

  # THE THREE-LAYER SET THE PANEL RENDERS AS A BOARD: top copper, bottom copper, drill. Named
  # `<stem>.gtl` etc. because tracespace identifies a layer from its FILENAME, so these extensions
  # are what put each file on the right side of the stackup.
  def write_gerber_set!(stem: "board", parent_node_id: nil)
    { gtl: write_gerber!(name: "#{stem}.gtl", parent_node_id:),
      gbl: write_gerber!(name: "#{stem}.gbl", parent_node_id:),
      drl: write_gerber!(name: "#{stem}.drl", parent_node_id:, body: MINIMAL_DRILL) }
  end
end
