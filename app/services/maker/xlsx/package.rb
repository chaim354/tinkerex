require "zip"

module Maker
  module Xlsx
    # THE ZIP, OPENED UNDER THREE BOUNDS AND WRITTEN BACK VERBATIM WHERE UNTOUCHED.
    #
    # THE BYTE BOUND IS TWO CHECKS AND NEEDS BOTH, files-preview.md's GerberZip rule applied to a
    # second reader: the DECLARED sizes are the pre-check (cheap, and honest about the ordinary
    # oversized workbook) and the CAPPED READ is the bound, because a declared size is a claim the
    # archive makes and rubyzip's inflater is not held to it. Each part is read with
    # `read(remaining + 1)` against a running total, so a zip that lies inflates at most one byte past
    # the budget before it is refused. The entry count is bounded too: a workbook is a few dozen
    # parts, and ten thousand empty entries is a cost with no workbook in it.
    #
    # Everything is held in memory as name => bytes, in the archive's own order, because a save
    # writes every part back and the parts it did not edit must be the parts it read.
    class Package
      MAX_BYTES = 20 * 1024 * 1024
      MAX_ENTRIES = 2_000
      MAX_INFLATED = 100 * 1024 * 1024

      # An OLE compound file: what Excel writes for a password-protected workbook (the zip is
      # encrypted inside one) and what a pre-2007 .xls is.
      OLE_MAGIC = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze
      ZIP_MAGIC = "PK".b.freeze

      def self.open(bytes) = new(bytes)

      attr_reader :entries

      def initialize(bytes)
        bytes = bytes.to_s.b
        if bytes.start_with?(OLE_MAGIC)
          raise Unreadable, "This workbook is password-protected or saved in the old .xls format, " \
                            "which this viewer cannot open."
        end
        raise Unreadable, "This file is not a readable .xlsx workbook." unless bytes.start_with?(ZIP_MAGIC)
        raise Unreadable, too_large if bytes.bytesize > MAX_BYTES

        @entries = read_entries(bytes)
        raise Unreadable, "This file is not a readable .xlsx workbook." unless @entries.key?("[Content_Types].xml")
      end

      def [](name) = @entries[name]
      def key?(name) = @entries.key?(name)
      def names = @entries.keys

      # The new archive: `replace` maps a part name to its new bytes (a name the package does not
      # have is appended), `remove` drops parts. Every other part is the bytes that were read.
      def write(replace: {}, remove: [])
        drop = remove.to_set
        out = Zip::OutputStream.write_buffer(StringIO.new) do |zos|
          @entries.each do |name, body|
            next if drop.include?(name)

            zos.put_next_entry(name)
            zos.write(replace.fetch(name, body))
          end
          replace.each do |name, body|
            next if @entries.key?(name)

            zos.put_next_entry(name)
            zos.write(body)
          end
        end
        out.string
      end

      private

      def too_large = "This workbook is too large to open here. Download it to open it in Excel or LibreOffice."

      def read_entries(bytes)
        out = {}
        Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
          files = zip.entries.reject(&:directory?)
          raise Unreadable, too_large if files.size > MAX_ENTRIES
          raise Unreadable, too_large if files.sum { |e| e.size.to_i } > MAX_INFLATED

          remaining = MAX_INFLATED
          files.each do |entry|
            body = entry.get_input_stream { |io| io.read(remaining + 1) }.to_s.b
            raise Unreadable, too_large if body.bytesize > remaining

            remaining -= body.bytesize
            out[entry.name.dup.force_encoding(Encoding::UTF_8)] = body
          end
        end
        out
      rescue Zip::Error, Zlib::Error
        raise Unreadable, "This file is not a readable .xlsx workbook."
      end
    end
  end
end
