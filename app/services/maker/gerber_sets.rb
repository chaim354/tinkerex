module Maker
  # WHICH GERBER FILES MAKE UP ONE BOARD — the Fabrication panel's whole model, shared by the
  # private project page and the public one so the two can never disagree about what a board is
  # (the same argument `Maker::PublicProject#kicad_rows` makes for the Schematics list, one layer
  # up: there the shared thing is an extension list, here it is a grouping).
  #
  # A BOARD IS A FOLDER, NOT A PROJECT. A project can hold several boards — a main board and a
  # daughterboard, or v1 and v2 — and a maker keeps each one's export in its own directory, because
  # that is the shape a board house is handed. So the grouping key is the PARENT DIRECTORY, and
  # every `pcb`-role file directly inside one is one board's set. Grouping by project instead would
  # stack two boards' copper layers on top of each other and render an image of nothing real.
  # A ZIPPED EXPORT IS THE OTHER KIND OF BOARD — its own, never merged into the folder it sits in
  # (`archive_boards` below, and `Maker::GerberArchive` for what the server reads out of it).
  #
  # A `.gbrjob` OVERRULES THE DIRECTORY, AND ONLY DOWNWARD. The Gerber job file is the export's own
  # manifest — `FilesAttributes[].Path` names exactly the layers that belong to the board — so where
  # one exists and parses, its list is what gets stacked. That matters for the ordinary messy
  # folder: an old revision left beside the current export, or a second board's stray layer, is
  # LISTED (the panel shows every pcb file in the directory, so nothing goes invisible) and simply
  # not STACKED. Where there is no job, or it does not parse, every pcb file in the directory is the
  # set — the honest answer when nothing has told us otherwise, and the one that keeps a hand-made
  # export working.
  #
  # THE JOB IS MATCHED BY BASENAME AMONG THE DIRECTORY'S OWN SIBLINGS, NEVER BY PATH. `Path` in a
  # `.gbrjob` is written by the CAM tool and may carry any prefix the exporter felt like (KiCad
  # writes a bare name, some tools write `./name`, some an absolute path from the author's machine).
  # Resolving it as a path would reach outside the folder — or, on a library where a name repeats,
  # at the wrong file. `File.basename` against the rows already in hand cannot do either, and a name
  # the directory does not hold is simply dropped.
  #
  # `.gbrjob` IS NEVER ITSELF STACKED. It is JSON; handing it to tracespace's Gerber parser produces
  # a junk layer rather than an error, which is the worst of both — so it is filtered out of
  # `stacked` unconditionally, including in the `no job` branch where it would otherwise ride along
  # as an ordinary `pcb` row.
  #
  # NO QUERIES AT ALL, AND ONE PORT READ PER JOB FILE. The rows come from
  # `Maker::ProjectFolderListing` and are already in memory, so the grouping is constant in N —
  # what `test/integration/web/page_query_budget_test.rb` measures. The job read is a port call
  # (`File.binread` on share), never `sql.active_record`, so it cannot show up in that budget
  # either; it is bounded by `READ_LIMIT` and by the number of `.gbrjob` files a folder holds, and
  # every failure mode degrades to the directory branch rather than raising into the page.
  class GerberSets
    # ONE BOARD. `rows` is everything the panel LISTS (every pcb-role row in the directory, name
    # ordered); `stacked` is the subset the viewer renders. They are different lists on purpose —
    # see the class comment — and a panel that rendered `stacked` as its file list would silently
    # hide the stray files that are the reason the distinction exists.
    #
    # `archive` is nil for a folder's loose set, and for a zipped export it is the zip's own Row plus
    # the member paths the viewer stacks — the one shape both Fabrication partials and the file page
    # hand to gerber_controller.js through FilesHelper#gerber_layers_for. `rows` is then exactly
    # [the zip's row] (the panel LISTS the archive, one line, badge "archive") and `stacked` is empty:
    # what is stacked lives in the zip, not in the catalog.
    Board = Data.define(:dir_node_id, :section, :name, :rows, :stacked, :archive)
    Archive = Data.define(:row, :members)

    # A `.gbrjob` past this is not read. It is JSON naming a few dozen files; anything larger is not
    # a job file, and reading it would be a stream of arbitrary length off the user's NAS into this
    # request for nothing (`Maker::Readme::READ_LIMIT` makes the identical argument, and for the
    # identical reason: the catalog already knows the size, so the check costs no read at all).
    READ_LIMIT = 512 * 1024

    # `rows` are `Maker::ProjectFolderListing::Row`s — whatever the caller was going to render
    # anyway. `user` is whose library the job files are read from: on the public page that is the
    # OWNER, never the visitor, who has no library for a node_id to resolve against.
    def self.for(user:, rows:) = new(user:, rows:).boards

    # THE BASENAMES ONE `.gbrjob` NAMES, or nil when there is nothing usable — PUBLIC because
    # `FilesController#show` asks the identical question with no listing in hand (a `.gbrjob`'s own
    # file page stacks the siblings the job names), and two spellings of "what does this manifest
    # say" is the pair that drifts. Takes a NODE rather than a Row for exactly that reason: the file
    # page holds one and the panel holds the other.
    #
    # EVERY FAILURE MODE COLLAPSES TO nil ON PURPOSE — an unreadable file, an unmounted share,
    # invalid JSON, a JSON document that is not an object, a missing or wrongly-shaped
    # `FilesAttributes`. Both callers answer all of them the same way (use the directory), so
    # distinguishing them here would be a branch nothing acts on.
    #
    # `rescue JSON::ParserError` BESIDE THE PORT'S OWN TWO, NEVER A BARE `rescue`: a job file is
    # user data and malformed JSON is routine, but a NoMethodError in this method is a bug and must
    # stay loud.
    def self.job_layer_names(user:, node:)
      return nil if node.size.to_i > READ_LIMIT

      bytes = FileLayer.current.read(user, node_id: node.node_id)
      doc = JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8).scrub)
      return nil unless doc.is_a?(Hash)

      names = Array(doc["FilesAttributes"]).filter_map do |entry|
        File.basename(entry["Path"].to_s) if entry.is_a?(Hash) && entry["Path"].present?
      end
      names.any? ? names.to_set : nil
    rescue FileLayer::NotFound, FileLayer::FetchError, JSON::ParserError
      nil
    end

    def initialize(user:, rows:)
      @user = user
      @rows = rows
    end

    # Boards in the order their directories read on the page: the folder's own root first (section
    # ""), then every subfolder by its display path. `sort_by` on the section alone would put "" in
    # front for free, but only by luck of the empty string sorting first — the pair below says it.
    #
    # THE NAME BREAKS A TIE THE SECTION NO LONGER CAN. One section used to hold at most one board,
    # so sorting on it alone was total; a zip beside a loose set puts two boards in one directory,
    # and `sort_by` is not stable in Ruby — without the name they would swap between runs.
    def boards
      @boards ||= (folder_boards + archive_boards)
                    .sort_by { |board| [ board.section.empty? ? 0 : 1, board.section, board.name ] }
    end

    private

    def folder_boards
      @rows.select { |row| gerber?(row.node.name) }
           .group_by { |row| row.node.parent_node_id }
           .map { |dir_node_id, dir_rows| board_for(dir_node_id, dir_rows) }
    end

    # A ZIP IS NEVER MERGED INTO ITS FOLDER'S LOOSE SET. An export is complete by construction —
    # stacking a folder's stray `.gtl` on top of a zip's own top copper would render two revisions
    # as one board, the exact image-of-nothing-real the folder rule exists to prevent. A zip whose
    # listing is nil (not a Gerber export, unreadable, too big) is simply not a board.
    def archive_boards
      @rows.select { |row| GerberArchive.archive?(row.node.name) }.filter_map do |row|
        listing = GerberArchive.for(user: @user, node: row.node) or next

        Board.new(dir_node_id: row.node.parent_node_id, section: row.section.to_s,
                  name: File.basename(row.node.name, ".*"), rows: [ row ], stacked: [],
                  archive: Archive.new(row:, members: listing.stacked))
      end
    end

    def gerber?(name) = FilesController::GERBER_EXTS.include?(ext_of(name))

    def ext_of(name) = File.extname(name.to_s).downcase.delete(".")

    def board_for(dir_node_id, dir_rows)
      rows = dir_rows.sort_by { |row| row.node.name }
      jobs, layers = rows.partition { |row| ext_of(row.node.name) == "gbrjob" }
      # LAZY: only the first job that answers is READ. Each read is a port call (a public page
      # triggers it anonymously), so a directory holding several job files must not pay for all
      # of them when the first names the set (the review measured the eager form reading every one).
      listed = jobs.lazy.filter_map { |job| self.class.job_layer_names(user: @user, node: job.node) }.first
      stacked = listed ? layers.select { |row| listed.include?(row.node.name) } : layers
      # A JOB THAT NAMES NOTHING THIS FOLDER HOLDS FALLS BACK RATHER THAN RENDERING AN EMPTY BOARD.
      # That is the exported-then-renamed case (a maker unzips into a folder and renames the files),
      # and an empty stage with a full file list beside it reads as a broken viewer.
      stacked = layers if stacked.empty?
      # `section` is the listing's own display path relative to the project folder, so the panel's
      # heading agrees with the Files panel's section headings for free — never a path rebuilt here.
      section = rows.first.section.to_s
      Board.new(dir_node_id:, section:, name: board_name(jobs, section), rows:, stacked:, archive: nil)
    end

    # The board's name: the job file's own stem where there is one (a CAM tool names it after the
    # board), else the directory's own name, else "Board" for a set sitting loose at the project
    # folder's root, which has no directory name to borrow.
    def board_name(jobs, section)
      job = jobs.first
      return File.basename(job.node.name, ".*") if job

      section.split("/").last.presence || "Board"
    end
  end
end
