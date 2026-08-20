require "test_helper"

module Maker
  class ExtractPdfMetadataJobTest < ActiveSupport::TestCase
    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
      @user  = User.create!(email: "pdf-#{SecureRandom.hex(3)}@example.com")
      @model = @user.maker_models.create!(title: "Honeycomb Storage Wall")
      @node  = @user.nodes.create!(node_id: "pdf1", name: "152592-honeycomb-x.pdf", kind: "file")
      @text  = File.read(Rails.root.join("test/fixtures/files/printables_honeycomb_pdfium.txt"), encoding: "UTF-8")
    end

    # Stub the byte-read + pdfium (the repo's define_singleton_method idiom, e.g.
    # generate_preview_job_test.rb) so the parser runs on the real fixture text with no binary and no
    # file content. `pdf_text` lets a case return nil ("no extractable text").
    def run_job(pdf_text: @text)
      orig_read = Maker::FileBytes.method(:read)
      orig_extract = Maker::PdfText.method(:extract)
      orig_avail = Maker::PdfText.method(:available?)
      Maker::FileBytes.define_singleton_method(:read) { |*, **| "%PDF-fake" }
      Maker::PdfText.define_singleton_method(:extract) { |*| pdf_text }
      Maker::PdfText.define_singleton_method(:available?) { true } # don't depend on a local pdfium
      Maker::ExtractPdfMetadataJob.new.perform(model_id: @model.id, node_id: "pdf1")
    ensure
      Maker::FileBytes.define_singleton_method(:read, orig_read)
      Maker::PdfText.define_singleton_method(:extract, orig_extract)
      Maker::PdfText.define_singleton_method(:available?, orig_avail)
    end

    test "fills empty fields from the parsed PDF" do
      run_job
      @model.reload
      assert_equal "RostaP", @model.designer
      assert_equal "CC BY-NC 4.0", @model.license
      assert_equal "https://www.printables.com/model/152592", @model.source_url
      assert_match(/Wall for attaching hooks/, @model.notes)
      assert_equal "PET", @model.print_settings["material"]
      assert_equal "0.28 mm", @model.print_settings["layer_height"]
      assert_includes @model.tags.map(&:name), "organizer"
    end

    test "never overwrites fields the user already set (incl. notes and print_settings)" do
      @model.update!(designer: "MINE", license: "My License", notes: "my own notes",
                     print_settings: { "material" => "MYPLA" })
      run_job
      @model.reload
      assert_equal "MINE", @model.designer
      assert_equal "My License", @model.license
      assert_equal "my own notes", @model.notes                    # not clobbered
      assert_equal({ "material" => "MYPLA" }, @model.print_settings) # not clobbered
      # source_url WAS blank -> it still gets filled
      assert_equal "https://www.printables.com/model/152592", @model.source_url
    end

    test "tags are additive (union), not replaced" do
      @model.tag_list = "existing"
      @model.save!
      run_job
      names = @model.reload.tags.map(&:name)
      assert_includes names, "existing"
      assert_includes names, "organizer"
    end

    test "no-op when the PDF has no extractable text" do
      run_job(pdf_text: nil)
      assert_nil @model.reload.designer
    end

    test "gone model / node is a safe no-op" do
      assert_nothing_raised do
        Maker::ExtractPdfMetadataJob.new.perform(model_id: 0, node_id: "nope")
        Maker::ExtractPdfMetadataJob.new.perform(model_id: @model.id, node_id: "nope")
      end
    end
  end
end
