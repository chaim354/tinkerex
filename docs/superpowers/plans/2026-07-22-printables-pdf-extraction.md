# Printables PDF Metadata Extraction — Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. TDD; frequent commits.

**Goal:** On import, parse a Printables instructions PDF and auto-fill the model's EMPTY fields (designer, license, source, tags, description) plus a new `print_settings` JSON blob — never overwriting user input.

**Architecture:** A pure parser (`Maker::PrintablesPdf`, text→hash) + a pdfium text wrapper (`Maker::PdfText`) + a background job (`Maker::ExtractPdfMetadataJob`) enqueued when an instructions PDF is attached. Text extraction uses the **bundled pdfium** (`text` subcommand, permissive §9). The parser is **validated against a real pdfium fixture** (`test/fixtures/files/printables_honeycomb_pdfium.txt`, already in the branch).

**Spec:** `docs/superpowers/specs/2026-07-22-printables-pdf-extraction-design.md`

**pdfium reality (why the parser looks the way it does):** pdfium reads a Printables PDF with values exploded across lines, icon-font glyphs as stray single letters (`f`/`k`/`h`/`d`), and the title/author block emitted AFTER the changelog. So every field is anchored by pattern, and the **designer** is found by peeling the known title off the lines above `VIEW IN BROWSER`. Call pdfium with `--text-page-header=false` to drop "Page N".

---

## Task 1: `print_settings` JSON column

- [ ] **Test** (`test/models/maker/model_test.rb`, append): round-trips a Hash.
```ruby
    test "print_settings stores and returns a Hash" do
      m = @user.maker_models.create!(title: "x", print_settings: { "material" => "PET" })
      assert_equal({ "material" => "PET" }, m.reload.print_settings)
      assert_nil @user.maker_models.create!(title: "y").print_settings
    end
```
- [ ] **Run** → red. `bin/rails test test/models/maker/model_test.rb -n /print_settings/`
- [ ] **Migration**: `bin/rails g migration AddPrintSettingsToMakerModels`, body: `add_column :maker_models, :print_settings, :json`
- [ ] **Migrate + run** → green. `bin/rails db:migrate && bin/rails test test/models/maker/model_test.rb`
- [ ] **Commit**: `feat(models): print_settings json column`

## Task 2: `Maker::PrintablesPdf` parser (validated code)

- [ ] **Test** (`test/services/maker/printables_pdf_test.rb`) — the fixture is already at `test/fixtures/files/printables_honeycomb_pdfium.txt`:
```ruby
require "test_helper"
module Maker
  class PrintablesPdfTest < ActiveSupport::TestCase
    TEXT = File.read(Rails.root.join("test/fixtures/files/printables_honeycomb_pdfium.txt"), encoding: "UTF-8")

    test "extracts every field from a real Printables PDF's pdfium text" do
      d = Maker::PrintablesPdf.extract(text: TEXT, filename: "152592-honeycomb-storage-wall-x.pdf", title: "Honeycomb Storage Wall")
      assert_equal "RostaP", d[:designer]
      assert_equal "CC BY-NC 4.0", d[:license]
      assert_match(/Wall for attaching hooks/, d[:description])
      assert_equal %w[organizer wall hooks storrage], d[:tags]
      assert_equal "https://www.printables.com/model/152592", d[:source_url]
      ps = d[:print_settings]
      assert_equal "0.28 mm", ps["layer_height"]
      assert_equal "0.40 mm", ps["nozzle"]
      assert_equal "PET", ps["material"]
      assert_equal "58 g", ps["filament"]
      assert_equal "3.88 hrs", ps["print_time"]
      assert_equal "Household > Other House Equipment", ps["category"]
      assert_match(/Prusa MINI/, ps["printer"])
    end

    test "non-Printables / blank text yields {} and never raises" do
      assert_equal({}, Maker::PrintablesPdf.extract(text: "random text\nno structure", filename: "x.pdf", title: "X"))
      assert_equal({}, Maker::PrintablesPdf.extract(text: nil, filename: nil, title: nil))
    end
  end
end
```
- [ ] **Run** → red.
- [ ] **Implement** `app/services/maker/printables_pdf.rb` (this exact code is validated against the fixture):
```ruby
module Maker
  # Parse a Printables model PDF's TEXT (as produced by pdfium) into model metadata. PURE:
  # (text, filename, title) -> a Hash of only the fields it found. Tuned to how pdfium reads a
  # Printables PDF (values exploded across lines, icon glyphs as stray single letters, the
  # title/author block emitted after the changelog), so fields are anchored by pattern, never by
  # absolute position; a miss omits the key instead of raising. A non-Printables PDF yields little.
  module PrintablesPdf
    module_function

    MATERIALS = %w[PCTG PETG NYLON PLA PET ABS TPU ASA PVA HIPS PP PA PC].freeze # longest-first

    def extract(text:, filename: nil, title: nil)
      lines = text.to_s.scrub.split("\n").map { |l| l.gsub(/\s+/, " ").strip }
      {
        designer:       designer(lines, title),
        license:        license(lines),
        description:    description(lines),
        tags:           tags(lines),
        source_url:     source_url(filename),
        print_settings: print_settings(lines)
      }.reject { |_, v| v.blank? }
    end

    # Author sits above the title, which sits above the "VIEW IN BROWSER" button. We know the
    # model's title, so peel the title lines off (all their words are in the title); the first line
    # above them is the author.
    def designer(lines, title)
      i = lines.index("VIEW IN BROWSER")
      return nil unless i
      title_words = title.to_s.downcase.scan(/[a-z0-9]+/)
      return nil if title_words.empty?
      j = i - 1
      j -= 1 while j >= 0 && (w = lines[j].downcase.scan(/[a-z0-9]+/)).any? && w.all? { |x| title_words.include?(x) }
      return nil if j == i - 1 # nothing above matched the title -> anchor unreliable
      author = lines[j].to_s.strip
      return nil if author.blank? || author.length > 40 || author.include?(">")
      author
    end

    def license(lines)
      i = lines.index { |l| l == "License" || l.start_with?("This work is licensed") }
      i && normalize_license(lines[i, 5].join(" "))
    end

    def normalize_license(s)
      d = s.downcase
      return "CC0 (Public Domain)" if d.include?("public domain") || d.include?("cc0")
      return nil unless d.include?("creative commons") || d.include?("attribution")
      parts = ["CC BY"]
      parts << "NC" if d.include?("noncommercial") || d.include?("non-commercial")
      parts << "SA" if d.include?("sharealike") || d.include?("share-alike")
      parts << "ND" if d.include?("noderiv")
      [parts.join("-"), s[/\b(\d\.\d)\b/, 1]].compact.join(" ")
    end

    def description(lines)
      i = lines.index("Summary")
      return nil unless i
      body = []
      lines[(i + 1)..].each do |l|
        break if l.blank? || l.match?(/\A.+\s>\s.+\z/) || l.start_with?("News", "Tags:")
        body << l
      end
      body.join(" ").presence
    end

    def tags(lines)
      line = lines.find { |l| l.start_with?("Tags:") }
      line&.sub(/\ATags:\s*/, "")&.split(/\s+/)&.reject(&:blank?)
    end

    def source_url(filename)
      id = filename.to_s[/\A(\d+)-/, 1]
      id && "https://www.printables.com/model/#{id}"
    end

    def print_settings(lines)
      ps = {}
      mm = lines.select { |l| l.match?(/\A[\d.]+\s*mm\z/) }
      ps["layer_height"] = mm[0] if mm[0]
      ps["nozzle"]       = mm[1] if mm[1]
      ps["print_time"] = lines.find { |l| l.match?(/\A[\d.]+\s*hrs\z/) }
      ps["material"]   = lines.find { |l| MATERIALS.include?(l.upcase) }
      ps["filament"]   = lines.find { |l| l.match?(/\A\d+\s*g\z/) }
      ps["category"]   = lines.find { |l| l.match?(/\A[^>]+\s>\s.+\z/) && !l.start_with?("Tags") }
      if (gi = lines.index { |l| l.match?(/\A\d+\s*g\z/) })
        printer = []
        lines[(gi + 1)..].each do |l|
          next if l.length <= 1 # icon glyph
          break if l.blank? || l == "Summary" || l.match?(/\A[\d.]/)
          printer << l
          break if printer.join(" ").length > 30
        end
        ps["printer"] = printer.join(" ").presence
      end
      ps.compact
    end
  end
end
```
- [ ] **Run** → green (all fields; the second test's `{}`).
- [ ] **Commit**: `feat(models): Maker::PrintablesPdf parser (validated vs real pdfium output)`

## Task 3: `Maker::PdfText` (pdfium wrapper)

- [ ] **Implement** `app/services/maker/pdf_text.rb`:
```ruby
require "open3"
module Maker
  # Plain text from a PDF via the bundled pdfium CLI (klippa, MIT/BSD, §9 — same binary
  # Maker::Previews::Pdf renders with). `--text-page-header=false` drops "Page N". Returns scrubbed
  # UTF-8 or nil if pdfium is unavailable/errors (feature then no-ops, like previews degrade).
  module PdfText
    module_function
    BIN = ENV.fetch("PDFIUM_BIN", "pdfium").freeze

    def available?
      Open3.capture2e(BIN, "--version"); true
    rescue StandardError
      false
    end

    def extract(path)
      out, status = Open3.capture2(BIN, "text", path.to_s, "-", "--text-page-header=false")
      status.success? ? out.scrub.presence : nil
    rescue StandardError
      nil
    end
  end
end
```
No unit test (thin wrapper; a hand-crafted PDF fixture is brittle) — covered by the live pdfium smoke in Task 6 and by the job test (which stubs `PdfText.extract`).
- [ ] **Commit**: `feat(models): Maker::PdfText — pdfium text extraction wrapper`

## Task 4: `Maker::ExtractPdfMetadataJob` + trigger

Before writing, check the FileLayer read API used by the preview pipeline (`grep -rn "def read\|\.read(" app/services/file_layer/*.rb app/services/maker/previews/`) and read a file's bytes into a tempfile the same way (chunk hydrates, share/s3 read). Use that in `read_pdf_text`.

- [ ] **Test** (`test/jobs/maker/extract_pdf_metadata_job_test.rb`): stub `Maker::PdfText.extract` to return the fixture text; assert fill-blanks + no-overwrite + tags union + print_settings. Run on default and `LIBRARY_BACKEND=share`.
```ruby
require "test_helper"
module Maker
  class ExtractPdfMetadataJobTest < ActiveSupport::TestCase
    setup do
      pin_file_layer_backend("chunk"); Storage::ChunkStore.reset!
      @user = User.create!(email: "pdf-#{SecureRandom.hex(3)}@e.com")
      @model = @user.maker_models.create!(title: "Honeycomb Storage Wall")
      @node = @user.nodes.create!(node_id: "pdf1", name: "152592-honeycomb-x.pdf", kind: "file")
      @text = File.read(Rails.root.join("test/fixtures/files/printables_honeycomb_pdfium.txt"), encoding: "UTF-8")
    end

    test "fills empty fields from the parsed PDF, never overwriting" do
      @model.update!(designer: "MINE")   # pre-set -> must survive
      Maker::PdfText.stub :extract, @text do
        Maker::ExtractPdfMetadataJob.new.perform(model_id: @model.id, node_id: "pdf1")
      end
      @model.reload
      assert_equal "MINE", @model.designer          # not overwritten
      assert_equal "CC BY-NC 4.0", @model.license   # filled
      assert_equal "PET", @model.print_settings["material"]
      assert_includes @model.tags.map(&:name), "organizer"
    end
  end
end
```
NOTE: the job reads bytes via the port; in this test the node has no content, but `PdfText.extract` is stubbed so `read_pdf_text` must still return the stubbed text. Make `read_pdf_text` call `Maker::PdfText.extract(path)` after fetching bytes — the stub intercepts regardless of the (empty) tempfile. If `stat` returns no content_token for the contentless test node, guard so the stub path is still reached: in the test, also stub the byte read, OR structure the job so `PdfText.extract` is the stubbable seam and byte-fetch failures short-circuit to nil BEFORE the stub — restructure the test to stub at the byte-read boundary if needed. (Resolve during implementation; the behavior asserted is the point.)
- [ ] **Run** → red.
- [ ] **Implement** `app/jobs/maker/extract_pdf_metadata_job.rb`:
```ruby
module Maker
  class ExtractPdfMetadataJob < ApplicationJob
    queue_as :default
    # Best-effort: parse a model's instructions PDF and fill only EMPTY fields. Never overwrites;
    # idempotent. Reads bytes via the FileLayer port for PROCESSING only (like the preview jobs) —
    # no sync/write, §10/§15 hold.
    def perform(model_id:, node_id:)
      model = Maker::Model.find_by(id: model_id)
      node  = model&.user&.nodes&.present&.find_by(node_id:)
      return unless node
      text = read_pdf_text(model.user, node)
      return if text.blank?
      apply(model, Maker::PrintablesPdf.extract(text:, filename: node.name, title: model.title))
    end

    private

    def read_pdf_text(user, node)
      Tempfile.create(["pdfmeta", ".pdf"]) do |tmp|
        tmp.binmode
        # Read the file's bytes via the port (mirror the preview pipeline's read), write to tmp.
        bytes = read_bytes(user, node)  # implement per the FileLayer read API check above
        return nil if bytes.blank?
        tmp.write(bytes); tmp.flush
        Maker::PdfText.extract(tmp.path)
      end
    rescue FileLayer::FetchError, FileLayer::NotFound
      nil
    end

    def apply(model, data)
      %i[designer license source_url].each { |f| model[f] = data[f] if model[f].blank? && data[f].present? }
      model.notes = data[:description] if model.notes.blank? && data[:description].present?
      model.print_settings = data[:print_settings] if model.print_settings.blank? && data[:print_settings].present?
      model.tag_list = (model.tags.map(&:name) + data[:tags]).uniq.join(", ") if data[:tags].present?
      model.save!
    end
  end
end
```
- [ ] **Trigger** in `app/controllers/models/attachments_controller.rb#create`, after `att` is created:
```ruby
      Maker::ExtractPdfMetadataJob.perform_later(model_id: @model.id, node_id: node.node_id) if att.role == "instructions"
```
- [ ] **Run** → green (default + `LIBRARY_BACKEND=share`).
- [ ] **Commit**: `feat(models): ExtractPdfMetadataJob — auto-fill blanks from the instructions PDF`

## Task 5: "Print settings" panel

- [ ] **Test** (`models_flow_test.rb`, append): a model with `print_settings` renders the panel.
```ruby
    test "show renders a print-settings panel when present" do
      user = sign_in
      m = user.maker_models.create!(title: "P", print_settings: { "material" => "PET", "layer_height" => "0.2 mm" })
      get model_path(m)
      assert_select ".model-print-settings dt", text: "Material"
      assert_select ".model-print-settings dd", text: "PET"
    end
```
- [ ] **Implement** in `app/views/models/show.html.erb` (sidebar, before the files section):
```erb
    <% if @model.print_settings.present? %>
      <section class="model-print-settings">
        <h2>Print settings</h2>
        <dl class="ps-grid">
          <% @model.print_settings.each do |k, v| %>
            <dt><%= k.tr("_", " ").capitalize %></dt><dd><%= v %></dd>
          <% end %>
        </dl>
      </section>
    <% end %>
```
- [ ] **CSS** (`models.css`):
```css
.model-print-settings { margin-bottom: 22px; }
.ps-grid { display: grid; grid-template-columns: auto 1fr; gap: 3px 12px; font-size: 13px; margin: 0; }
.ps-grid dt { color: #64748b; } .ps-grid dd { margin: 0; }
```
- [ ] **Run** → green.
- [ ] **Commit**: `feat(models): print-settings panel on the detail page`

## Task 6: Verify (3 backends + live pdfium)

- [ ] `bin/rails test` (chunk) → 0 failures.
- [ ] `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` → 0 failures; same for `LIBRARY_BACKEND=s3 LIBRARY_S3_*`.
- [ ] **Live pdfium smoke** (proves `pdfium text` + the parser on a real PDF end-to-end): on the box, `docker exec <share-web> pdfium text "<the honeycomb pdf>" - --text-page-header=false` returns text, and `Maker::PrintablesPdf.extract` of it yields the expected designer/license/print_settings.
- [ ] **Browser smoke** (local share server): import the honeycomb-style zip WITH a real-ish PDF; confirm the model's designer/license/source/tags/notes + print-settings panel fill in after the job runs.
