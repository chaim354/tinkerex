module Maker
  # WHAT A `.gbrjob` SAYS A BOARD IS MADE OF. The Gerber job file is the export's own manifest —
  # `FilesAttributes[].Path` names exactly the layers that belong to the board — so where one exists
  # and parses, its list is what a job file's own page stacks (FilesController#gerber_layers_for,
  # the one caller). Where there is no job, or it does not parse, every pcb-role sibling is the set:
  # the honest answer when nothing has told us otherwise, and the one that keeps a hand-made export
  # working. `Maker::GerberArchive` applies the same rule to a `.gbrjob` INSIDE a zip.
  #
  # THE JOB IS MATCHED BY BASENAME AMONG THE DIRECTORY'S OWN SIBLINGS, NEVER BY PATH. `Path` is
  # written by the CAM tool and may carry any prefix the exporter felt like (KiCad writes a bare
  # name, some tools write `./name`, some an absolute path from the author's machine). Resolving it
  # as a path would reach outside the folder — or, on a library where a name repeats, at the wrong
  # file. `File.basename` against the rows already in hand cannot do either, and a name the
  # directory does not hold is simply dropped.
  #
  # THIS CLASS USED TO GROUP A FOLDER'S GERBERS INTO BOARDS for the project pages' Fabrication
  # panels (one board per folder, a zip a board of its own, the list and the stack two different
  # lists). The panels went on 2026-09-06 — a Gerber is a file like any other on a project page and
  # the board renders on its own file page — and the grouping went with them; `git show
  # 2addf8f:app/services/maker/gerber_sets.rb` holds it should a board mode on a layer's page ever
  # want it back.
  class GerberSets
    # A `.gbrjob` past this is not read. It is JSON naming a few dozen files; anything larger is not
    # a job file, and reading it would be a stream of arbitrary length off the user's NAS into this
    # request for nothing (`Maker::Readme::READ_LIMIT` makes the identical argument, and for the
    # identical reason: the catalog already knows the size, so the check costs no read at all).
    READ_LIMIT = 512 * 1024

    # THE BASENAMES ONE `.gbrjob` NAMES, as a Set, or nil when there is nothing usable.
    #
    # EVERY FAILURE MODE COLLAPSES TO nil ON PURPOSE — an unreadable file, an unmounted share,
    # invalid JSON, a JSON document that is not an object, a missing or wrongly-shaped
    # `FilesAttributes`. The caller answers all of them the same way (use the directory), so
    # distinguishing them here would be a branch nothing acts on.
    #
    # `rescue JSON::ParserError` BESIDE THE PORT'S OWN TWO, NEVER A BARE `rescue`: a job file is
    # user data and malformed JSON is routine, but a NoMethodError in this method is a bug and must
    # stay loud. FetchError has an arm of its own because it is the one failure that is an OUTAGE:
    # it also raises the layout's banner (app/models/current.rb), and the answer is still nil.
    def self.job_layer_names(user:, node:)
      return nil if node.size.to_i > READ_LIMIT

      bytes = FileLayer.current.read(user, node_id: node.node_id)
      doc = JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8).scrub)
      return nil unless doc.is_a?(Hash)

      names = Array(doc["FilesAttributes"]).filter_map do |entry|
        File.basename(entry["Path"].to_s) if entry.is_a?(Hash) && entry["Path"].present?
      end
      names.any? ? names.to_set : nil
    rescue FileLayer::FetchError
      Current.library_unreachable = true
      nil
    rescue FileLayer::NotFound, JSON::ParserError
      nil
    end
  end
end
