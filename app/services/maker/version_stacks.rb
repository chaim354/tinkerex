module Maker
  # VERSION STACKS (shop-manual spec §9): files that are versions, backups or copies of ONE part,
  # grouped so a panel can show them as one figure. Computed on every read from the catalog, never
  # stored: a rename regroups at once, and `nodes` gains no column (CLAUDE.md §14a). The one stored
  # thing is a pull-out (Maker::StackExclusion), keyed by node_id so it survives a move (§14b).
  #
  # THE RULE, which test/services/maker/version_stacks_test.rb pins on catan's names verbatim:
  #
  #   1. ONE FOLDER, ONE FILE TYPE, LIVE FILES ONLY. Members share a parent node and an extension
  #      (case-insensitive). A directory, a symlink or a tombstone is never a member.
  #   2. A NAME IS COMPARED without its extension, case-insensitively, with the separators space,
  #      `_`, `-` and `.` folded together and runs collapsed, AFTER the markers below are parsed out
  #      of the unfolded name (where a separator still says which marker it belongs to). Markers
  #      are taken off in this order:
  #        a. BACKUP / COPY, trailing, repeatedly: `backup`, `bak`, `old`, `copy`, `copy N`, `(N)`.
  #           Such a member is a COPY, not a version.
  #        b. A TRAILING DATE, `m-d` or `m-d-yy(yy)`, as the last token after a space, `_` or `.`
  #           (`edge test 7-3`, `edge test 7-20-26`). A date anywhere else is part of the name, so
  #           `Screenshot 2024-07-16 at 10.35.23 AM` never stacks, and neither does the `07-16`
  #           tail of an ISO date.
  #        c. A VERSION, wherever it stands as or ends a token: `v<digits>`, optionally followed
  #           by `-digits`/`.digits` groups, on its own (`game box v1`, `gamebox-v6-plan` ->
  #           `gamebox plan`) or glued after letters (`boxv1-5` -> `box`, `carboxv1` -> `carbox`).
  #      A marker that would leave nothing is not a marker (`v2.svg` stays `v2`).
  #   3. A BARE TRAILING NUMBER IS A PART NUMBER, NEVER FOLDED. `game box 2` is a different part
  #      from `game box` (the spec insists), and `tokenbox-tests-1` is itself. It is also why
  #      Finder's `name 2` form is NOT read as a copy: only `copy N` and `(N)` are.
  #   4. A STACK HAS AT LEAST TWO MEMBERS, after pull-outs are set aside.
  #
  # LATEST is the most recently modified member that is not a copy, or the newest copy when every
  # member is one. Members run latest first, then by modified time descending, copies last. A tie
  # in modified time (a seeded or bulk-copied folder has many) falls to the name in NATURAL order,
  # descending, so `v10` beats `v9` and `7-20-26` beats `7-5`; then node_id, so the answer is
  # deterministic. Modified time is the catalog's `nodes.mtime` (nanoseconds); a nil reads as 0,
  # the same reading FilesController#sort_key makes.
  #
  # THE NAME is the latest member's name with its markers removed and its edge separators trimmed,
  # in the latest member's own spelling (`harbor-number`, `game box`); `key` is the folded form the
  # members agreed on.
  #
  # TWO HALVES. `group` is pure: plain values in, stacks out, no query, which is what the test
  # drives with catan's names. `for_nodes` and `in_folder` load what it needs in TWO queries
  # whatever the number of files — one pluck of the nodes, one of this user's pull-outs among
  # them — and never ask the port (§2: a metadata read answers from the local catalog).
  module VersionStacks
    module_function

    # `[[:space:]]`, not `\s`: Ruby's `\s` is ASCII-only, and macOS writes a NARROW NO-BREAK SPACE
    # (U+202F) before the AM/PM of a screenshot's name, as catan's own screenshots carry.
    SEP = /[[:space:]_.\-]/
    COPY_MARKER = /(?:#{SEP}+(?:backup|bak|old|copy(?:#{SEP}*\d+)?)|#{SEP}*\(\d+\))#{SEP}*\z/i
    # The lookbehind sits AFTER the leading separators, so the date must follow a space, `_` or
    # `.`: a `-` before it would read the tail of `2024-07-16` as a date.
    TRAILING_DATE = /#{SEP}*(?<=[[:space:]_.])(?<month>\d{1,2})-(?<day>\d{1,2})(?:-(?:\d{4}|\d{2}))?#{SEP}*\z/
    # Not preceded by anything but a separator, a letter or the start: `box2v3` keeps its `v3`.
    VERSION = /#{SEP}*(?<![^[:space:]_.\-\p{L}])v\d+(?:[-.]\d+)*(?=#{SEP}|\z)/i

    # What the core reads about one node.
    Entry = Data.define(:node_id, :parent_node_id, :name, :kind, :mtime)
    # What one name parses to: the folded `key`, the `display` spelling, and whether it is a copy.
    Parsed = Data.define(:ext, :key, :display, :copy)
    Member = Data.define(:node_id, :name, :mtime, :copy) do
      def copy? = copy
    end
    Stack = Data.define(:parent_node_id, :ext, :key, :name, :members) do
      def latest = members.first
      def node_ids = members.map(&:node_id)
      def size = members.size
    end

    # The stacks found in one set of nodes, and where each member sits. `excluded` is the pull-outs
    # among the nodes asked about, so a listing can offer "Put back" beside a file that stands
    # alone because the maker said so, without a second query.
    class Result
      attr_reader :stacks, :excluded

      def initialize(stacks, excluded: Set.new)
        @stacks = stacks.freeze
        @excluded = excluded.to_set.freeze
        @by_node_id = stacks.each_with_object({}) { |s, h| s.members.each { |m| h[m.node_id] = s } }.freeze
      end

      def stack_for(node_id) = @by_node_id[node_id]
      def stacked?(node_id) = @by_node_id.key?(node_id)
      def pulled_out?(node_id) = @excluded.include?(node_id)
      # How many files the stacks fold away: a listing of N files shows N - folded figures.
      def folded = @stacks.sum { |s| s.size - 1 }

      # A display order with each stack standing once, where its first member stood: an element
      # is a Stack, or the node_id of a file that stands alone.
      def collapse(node_ids)
        seen = Set.new.compare_by_identity
        node_ids.filter_map do |id|
          stack = @by_node_id[id]
          next id unless stack
          next if seen.include?(stack)

          seen << stack
          stack
        end
      end
    end

    EMPTY = Result.new([])

    # The stacks among `node_ids` (any order, any folders) in this user's library.
    def for_nodes(user, node_ids)
      ids = Array(node_ids).compact.uniq
      return EMPTY if ids.size < 2

      build(user.nodes.present.where(kind: "file", node_id: ids), user.maker_stack_exclusions.where(node_id: ids))
    end

    # The stacks in one folder, among the entries the Library shows there (Node.visible_entries).
    def in_folder(user, folder_node_id, show_hidden: false)
      scope = user.nodes.present.visible_entries(show_hidden).where(kind: "file", parent_node_id: folder_node_id)
      build(scope, user.maker_stack_exclusions.where(node_id: scope.select(:node_id)))
    end

    # The stacks among Node RECORDS the caller already holds (the project page's listing rows): no
    # query for the nodes, one for the pull-outs. The caller vouches the records are live.
    def for_records(user, records)
      files = records.select { |n| n.kind == "file" }
      return EMPTY if files.empty?

      excluded = user.maker_stack_exclusions.where(node_id: files.map(&:node_id)).pluck(:node_id)
      group(files.map { |n| Entry.new(n.node_id, n.parent_node_id, n.name, n.kind, n.mtime) }, excluded:)
    end

    def build(nodes, exclusions)
      entries = nodes.pluck(:node_id, :parent_node_id, :name, :kind, :mtime).map { |row| Entry.new(*row) }
      return EMPTY if entries.empty?

      group(entries, excluded: exclusions.pluck(:node_id))
    end

    # THE PURE CORE: Entries in, a Result out.
    def group(entries, excluded: [])
      excluded = excluded.to_set
      buckets = Hash.new { |h, k| h[k] = [] }
      entries.uniq(&:node_id).each do |entry|
        next unless entry.kind == "file"
        next if excluded.include?(entry.node_id)

        parsed = parse(entry.name) or next
        buckets[[ entry.parent_node_id, parsed.ext, parsed.key ]] << [ entry, parsed ]
      end

      stacks = buckets.filter_map do |(parent_node_id, ext, key), pairs|
        next if pairs.size < 2

        ordered = order(pairs)
        Stack.new(parent_node_id:, ext:, key:, name: ordered.first.last.display, members: ordered.map(&:first))
      end
      Result.new(stacks.sort_by { |s| [ s.parent_node_id.to_s, s.key, s.ext ] }, excluded:)
    end

    # One file name -> Parsed, or nil for a name that cannot be compared (not valid UTF-8: a NAS
    # name is not guaranteed to be, §14b, and a scrubbed one could collide with a stranger).
    def parse(name)
      name = name.to_s.dup.force_encoding(Encoding::UTF_8)
      return nil unless name.valid_encoding?

      ext = File.extname(name)
      stem = name.delete_suffix(ext)
      copy = false

      while (m = COPY_MARKER.match(stem)) && meaningful?(m.pre_match)
        stem = m.pre_match
        copy = true
      end
      if (m = TRAILING_DATE.match(stem)) && date?(m) && meaningful?(m.pre_match)
        stem = m.pre_match
      end
      versionless = stem.gsub(VERSION, "")
      stem = versionless if meaningful?(versionless)

      Parsed.new(ext: ext.downcase, key: stem.downcase.gsub(/#{SEP}+/, " ").strip,
                 display: stem.gsub(/\A#{SEP}+|#{SEP}+\z/, ""), copy:)
    end

    def meaningful?(text) = text.match?(/[^[:space:]_.\-]/)

    def date?(match) = (1..12).cover?(match[:month].to_i) && (1..31).cover?(match[:day].to_i)

    # [Member, Parsed] pairs, latest first: not-a-copy, then newest, then name in natural order
    # descending, then node_id.
    def order(pairs)
      pairs.map { |entry, parsed|
        [ Member.new(node_id: entry.node_id, name: entry.name, mtime: entry.mtime.to_i, copy: parsed.copy), parsed ]
      }.sort { |(a, _), (b, _)|
        [ a.copy ? 1 : 0, b.mtime, natural(b.name), a.node_id ] <=> [ b.copy ? 1 : 0, a.mtime, natural(a.name), b.node_id ]
      }
    end

    # The name without its extension (one stack shares it, and its dot would outrank a space:
    # `game box.` > `game box v1`), digit runs compared as numbers. Every chunk is a
    # [rank, number, text] triple so any two compare.
    def natural(name)
      name.delete_suffix(File.extname(name)).downcase.scan(/\d+|\D+/)
          .map { |t| t.match?(/\A\d/) ? [ 0, t.to_i, "" ] : [ 1, 0, t ] }
    end
  end
end
