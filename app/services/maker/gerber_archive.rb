require "zip"

module Maker
  # A ZIPPED GERBER EXPORT IS A BOARD, AND THIS IS THE ONE PLACE THE SERVER LOOKS INSIDE THE ZIP.
  #
  # Every CAM tool hands a board over as a zip — Fusion 360's "CAM outputs", Altium's job outputs,
  # KiCad's fabrication plugin, EasyEDA/JLCPCB's `Gerber_*.zip` — and that zip is the artefact the
  # fab house takes, so a maker keeps it as it arrived. The old answer was "unzip it into the
  # folder"; the report that made this class exist was Finder refusing to do exactly that on the
  # SMB share.
  #
  # THE SERVER LISTS, THE BROWSER EXTRACTS. rubyzip reads the central directory here — names and
  # sizes, never a byte of a layer — and gerber_controller.js opens the same zip with JSZip to pull
  # the members this class named. Rails extracting layers and serving them would be bytes flowing
  # through the control plane on every backend (§15); the browser already has to fetch the zip to
  # render it, so it is the one that unpacks it.
  #
  # ONE PORT READ PER ZIP, BOUNDED TWICE, THEN CACHED. `READ_LIMIT` is judged on the catalog's own
  # `size` column BEFORE any read (`Maker::GerberSets::READ_LIMIT` makes the same argument for a job
  # file: the size is already known, so refusing costs nothing), and the job member is read only if
  # its own uncompressed size is under the job cap. The listing is a pure function of the bytes, so
  # it is cached in Rails.cache by `(node_id, content token)` — a re-exported zip has a new token
  # and reads again; an unchanged one is never opened twice. nil IS CACHED TOO: a zip of firmware
  # is not a board and stays not-a-board until its content changes, and re-reading a 10 MB archive
  # on every project-page view to re-learn that would be the cost this cache exists to avoid.
  # (test: null_store, so every test really reads; production: Solid Cache, one query per fetch.)
  #
  # A `.gbrjob` MEMBER PICKS THE STACK, DOWNWARD ONLY — `Maker::GerberSets.job_layer_names`'s rule
  # for a folder's job file, applied inside the archive: where a job parses and names members this
  # zip holds, those are stacked; every pcb-role member is still LISTED; a job naming nothing here
  # falls back to every layer. Matched by basename, never by path, for that method's reason
  # (exporters write any prefix). The job is never itself a layer (JSON into tracespace is a junk
  # layer, not an error).
  #
  # MEMBER NAMES ARE HANDED TO THE BROWSER AS PATHS AND TO tracespace AS BASENAMES. JSZip looks a
  # member up by its full path; tracespace identifies a layer by its filename, and Fusion's
  # `copper_top_l1.gbr` under three directories is identified by exactly the basename (probed).
  # Names are scrubbed to UTF-8 for the JSON attribute; a zip written with a non-UTF-8 name would
  # miss its member in JSZip and fail the board loudly ("could not load") rather than silently.
  # THE SERVER-SIDE READER MUST LOOK MEMBERS UP BY THE SAME SCRUBBED NAME — `entries_by_name` below
  # is that one door, and `zip.find_entry` is not it.
  #
  # EVERY FAILURE COLLAPSES TO nil — not a zip, a corrupt zip, an unreadable or unmounted store, a
  # zip with no Gerber member at all — because every caller answers all of them the same way (not
  # a board). `rescue Zip::Error` beside the port's own two, never a bare rescue: a NoMethodError
  # here is a bug and must stay loud.
  class GerberArchive
    # `members`: every pcb-role member path in the zip (String, name-ordered) — what the archive
    # HOLDS. `stacked`: the subset the VIEWER renders (never the .gbrjob), and the one field `app/`
    # reads (`FilesController#show`, into the browser's one archive entry). `job_name`: the job
    # member's basename, or nil.
    #
    # `members` AND `job_name` HAVE HAD NO READER IN `app/` since the project pages' Fabrication
    # panels went on 2026-09-06, and are kept deliberately: this class's tests pin the two lists as
    # DIFFERENT (a job naming a subset stacks that subset while every pcb-role member stays listed),
    # which is the behaviour a caller of either would depend on, and a member list is the next thing
    # a zip's own page will want to show.
    Listing = Data.define(:members, :stacked, :job_name)

    EXT = "zip".freeze
    # A Gerber export is a few hundred KB to a few MB (the report's 4-layer board: 300 KB zipped,
    # 1.2 MB flat). 16 MB is generous; past it the zip is something else, and reading it to find out
    # would stream that much off the user's store into a page request for nothing.
    READ_LIMIT = 16 * 1024 * 1024
    CACHE_TTL = 30.days

    def self.archive?(name) = File.extname(name.to_s).downcase.delete(".") == EXT

    # nil unless this node is a zip holding at least one Gerber layer. `user` is whose library the
    # bytes are read from — the file page's current user.
    #
    # THE TOKEN IS `content_hash` OR `current_version_id`, WHICH IS THE PORT'S OWN `content_token`
    # SPELLED FROM THE CATALOG: a hash on share/s3, a version id on chunk_remote — the same value
    # `Maker::Previews::MissingBackfill` gets from the port's bulk `stat_all`. It is read off the
    # two columns here, and nowhere else in `app/`, because asking the port for `stat` would cost
    # a second call on every project-page board just to build a cache key. (`Node` has no
    # `current_version` reader; the column is `current_version_id`.)
    #
    # AN UNKNOWN SIZE IS REFUSED, NOT READ. `nodes.size` is nullable, and `nil.to_i` is 0 — which
    # would pass the guard and hand the read to the port's own 256 MB cap, sixteen times this
    # class's. Nothing writes a NULL size today (the scan and the mirror both set it); if one ever
    # appears, "bounded before any read" still has to mean what it says.
    def self.for(user:, node:)
      return nil unless archive?(node.name)
      return nil if node.size.nil? || node.size > READ_LIMIT

      token = node.content_hash.presence || node.current_version_id.presence
      Rails.cache.fetch([ "gerber-archive", node.node_id, token ], expires_in: CACHE_TTL) do
        read(user:, node:)
      end
    end

    def self.read(user:, node:)
      listing_from(FileLayer.current.read(user, node_id: node.node_id))
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end

    # PUBLIC AND PURE so the tests can hand it bytes directly; `for` is the cached, port-reading door.
    #
    # THE EMPTY GUARD IS NOT BELT AND BRACES — PROBED ON rubyzip 3.6.0: `Zip::File.open_buffer` on a
    # ZERO-length buffer raises `TypeError: no implicit conversion of StringIO into String` rather
    # than `Zip::Error` (every other malformed input, "PK" included, raises `Zip::Error` correctly).
    # A zero-byte `.zip` is an ordinary artefact of an interrupted export, and without this line it
    # would take a file page and a project page down with a 500. It is a guard rather than a
    # `rescue TypeError`, which would be broad enough to swallow a real bug in this method.
    #
    # BOTH EXITS FROM THE BLOCK ARE AN EXPLICIT `return`, AND THAT IS LOAD-BEARING — do not "tidy"
    # either into a trailing expression. `Zip::File.open_buffer` DISCARDS its block's value and
    # answers `zf.write_buffer(io)` instead (rubyzip 3.6.0, lib/zip/file.rb:147-153), so a Listing
    # left as the block's last expression is thrown away and this method hands its caller the
    # StringIO — which then fails at the cache as `TypeError: no _dump_data is defined for class
    # StringIO`, a page-breaking error nowhere near the mistake. Returning also skips that
    # `write_buffer`, which re-serialises the whole archive back into a buffer nothing reads.
    def self.listing_from(bytes)
      zip = open_zip(bytes) or return nil

      names = []
      job = nil
      entries_by_name(zip).each do |name, entry|
        ext = ext_of(name)
        next unless FilesController::GERBER_EXTS.include?(ext)

        if ext == "gbrjob"
          job ||= entry
        else
          names << name
        end
      end
      return nil if names.empty?

      names.sort!
      listed = job && job_layer_names(job)
      stacked = listed ? names.select { |n| listed.include?(File.basename(n)) } : names
      stacked = names if stacked.empty?
      Listing.new(members: names, stacked:, job_name: job && File.basename(scrub_name(job.name)))
    rescue Zip::Error
      nil
    end

    # THE ONE PLACE A MEMBER NAME IS SCRUBBED, and it is public because TWO readers need the same
    # answer. `listing_from` above reports scrubbed names, and `Maker::Previews::GerberZip` then has
    # to find the ENTRY behind one of them: `Zip::Entry#name` is ASCII-8BIT as read off the archive,
    # so `zip.find_entry(scrubbed)` MISSES on any non-ASCII name — a board holding `Cámara_top.gbr`
    # answered `unsupported` with nothing wrong with it (probed in review). Scrubbing in two places
    # is the drift this method exists to prevent: this repo's dominant failure shape is one rule
    # spelled at one door and not at the next (§14b).
    #
    # Directories are dropped here rather than by each caller — `listing_from` skipped them and the
    # renderer never wants one. LAST WINS on a name collision, which is `index_by`'s rule and not a
    # decision: two members whose scrubbed names collide are a degenerate archive either way, and
    # the board still renders from whichever entry the map kept.
    def self.entries_by_name(zip)
      zip.entries.reject(&:directory?).index_by { |entry| scrub_name(entry.name) }
    end

    def self.scrub_name(name) = name.to_s.dup.force_encoding(Encoding::UTF_8).scrub

    # THE ARCHIVE IS OPENED IN A RESCUE OF ITS OWN, NARROWER IN SCOPE AND WIDER IN CLASSES than the
    # method's — `Maker::ThreeMfManifest.open_zip` is the same door for the same reason. rubyzip
    # 3.6.0 does not fail cleanly on a central directory that is present but cut short: a real zip
    # minus its last 1, 5 or 10 bytes raises `NoMethodError` ("undefined method 'positive?' for
    # nil") or `ArgumentError` ("comparison of Integer with nil") out of `open_buffer`, not
    # `Zip::Error` (measured in the 3MF review; this reader raised identically on the same bytes,
    # and a truncated upload is an ordinary thing for a file page to meet). A method-level rescue of
    # those classes would also swallow this class's own bugs, which must stay loud — so the wide
    # list wraps exactly the gem's call. The block form is not used: it discards the block's value
    # and answers a re-serialised buffer. Empty bytes are refused first (`open_buffer` raises
    # TypeError on them).
    def self.open_zip(bytes)
      return nil if bytes.nil? || bytes.empty?

      Zip::File.open_buffer(StringIO.new(bytes.b))
    rescue Zip::Error, TypeError, NoMethodError, ArgumentError
      nil
    end

    # The same document rules as `Maker::GerberSets.job_layer_names`, for a member instead of a
    # node: the job's own uncompressed size is the cap, and every failure is nil (use the directory).
    def self.job_layer_names(entry)
      return nil if entry.size.to_i > Maker::GerberSets::READ_LIMIT

      doc = JSON.parse(entry.get_input_stream.read.force_encoding(Encoding::UTF_8).scrub)
      return nil unless doc.is_a?(Hash)

      names = Array(doc["FilesAttributes"]).filter_map do |item|
        File.basename(item["Path"].to_s) if item.is_a?(Hash) && item["Path"].present?
      end
      names.any? ? names.to_set : nil
    rescue JSON::ParserError, Zip::Error
      nil
    end

    def self.ext_of(name) = File.extname(name.to_s).downcase.delete(".")
  end
end
