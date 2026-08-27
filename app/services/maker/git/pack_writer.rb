require "zlib"
require "digest"
require "fileutils"

module Maker
  module Git
    # An UNDELTIFIED pack + idx v2 writer. Deltas are OPTIONAL in the pack format, so an
    # undeltified pack is a valid pack -- and this is the easy half of the packfile problem.
    # Reading deltified packs is the hard half, and this design never needs it: it only ever reads
    # packs it wrote.
    #
    # WHY IT EXISTS AT ALL: rugged has no packbuilder. Measured against the built gem (1.9.6), not
    # read off its README -- Rugged::Repository exposes 70 instance methods and NOT ONE matches
    # pack/repack/gc/prune, and Rugged::Packbuilder, Rugged::Indexer and Rugged::Odb are undefined.
    # Rugged::Backend exists with zero methods, so custom ODB backends are not merely "C, not Ruby":
    # they are unreachable from rugged at all.
    #
    # WHY UNDELTIFIED IS ACCEPTABLE: it costs 5x on BYTES against `git gc` (3.9 MB vs 784 KB at
    # 1,500 commits, measured) and buys the entire 390x FILE-COUNT reduction, which is the term
    # that actually matters -- an unpacked repo needs 11,287 GETs to hydrate on s3 against ~3.
    # Five times SMALL is still small, and it is only small because the tracking rule keeps
    # binaries out as pointers. IF THAT RULE IS EVER WEAKENED, THIS TRADE GOES WITH IT.
    module PackWriter
      TYPE = { "commit" => 1, "tree" => 2, "blob" => 3, "tag" => 4 }.freeze

      module_function

      # Loose object -> [type, raw payload]. Format on disk is zlib("<type> <len>\0<payload>").
      def read_loose(path)
        raw = Zlib::Inflate.inflate(File.binread(path))
        header, payload = raw.split("\0".b, 2)
        type, len = header.split(" ")
        raise "length mismatch in #{path}: header #{len}, actual #{payload.bytesize}" \
          unless payload.bytesize == len.to_i
        [ type, payload ]
      end

      # The per-object header: 3 type bits and a base-128 varint size, low 4 bits in the first byte
      # and 7 in each byte after. The MSB is the continuation flag, NOT part of the size.
      def object_header(type, size)
        out = +"".b
        byte = (TYPE.fetch(type) << 4) | (size & 0x0F)
        size >>= 4
        while size > 0
          out << (byte | 0x80).chr
          byte = size & 0x7F
          size >>= 7
        end
        out << byte.chr
      end

      # objects: [[oid_hex, type, payload], ...] — writes <dir>/pack-<sha>.pack and .idx
      def write(dir, objects)
        body = +"".b
        body << "PACK".b << [ 2 ].pack("N") << [ objects.size ].pack("N")

        entries = []
        objects.each do |oid, type, payload|
          offset = body.bytesize
          chunk = object_header(type, payload.bytesize) + Zlib::Deflate.deflate(payload)
          body << chunk
          entries << { oid: [ oid ].pack("H*"), offset:, crc: Zlib.crc32(chunk) }
        end

        pack_sha = Digest::SHA1.digest(body)
        body << pack_sha
        name = pack_sha.unpack1("H*")
        FileUtils.mkdir_p(dir)
        File.binwrite(File.join(dir, "pack-#{name}.pack"), body)
        File.binwrite(File.join(dir, "pack-#{name}.idx"), build_idx(entries, pack_sha))
        { name:, bytes: body.bytesize, count: objects.size }
      end

      # idx v2. Every table below is in SORTED-OID order and the fanout is CUMULATIVE — a fanout of
      # per-bucket counts parses without error and resolves the wrong objects.
      def build_idx(entries, pack_sha)
        entries = entries.sort_by { |e| e[:oid] }
        raise "large offsets (>2GiB) not supported by this writer" if entries.any? { |e| e[:offset] > 0x7FFFFFFF }

        idx = +"".b
        idx << "\xFFtOc".b << [ 2 ].pack("N")

        counts = Array.new(256, 0)
        entries.each { |e| counts[e[:oid].getbyte(0)] += 1 }
        total = 0
        counts.each { |c| total += c; idx << [ total ].pack("N") }

        entries.each { |e| idx << e[:oid] }
        entries.each { |e| idx << [ e[:crc] ].pack("N") }
        entries.each { |e| idx << [ e[:offset] ].pack("N") }

        idx << pack_sha
        idx << Digest::SHA1.digest(idx)
      end
    end
  end
end
