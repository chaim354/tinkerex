require "tempfile"

module Maker
  # Parse a model's instructions PDF (via pdfium + Maker::PrintablesPdf) and fill only its EMPTY
  # fields. Best-effort, never overwrites what the user typed, idempotent (safe to re-run). Reads
  # the bytes via the FileLayer port for PROCESSING only — exactly as the preview jobs do — so no
  # sync/write path is touched (§10/§15 hold). Enqueued when an instructions PDF is attached.
  class ExtractPdfMetadataJob < ApplicationJob
    queue_as :default

    def perform(model_id:, node_id:)
      model = Maker::Model.find_by(id: model_id)
      node  = model&.user&.nodes&.present&.find_by(node_id:)
      return unless node

      text = read_pdf_text(model.user, node)
      return if text.blank?

      data = Maker::PrintablesPdf.extract(text:, filename: node.name, title: model.title)
      apply(model, data)
    end

    private

    def read_pdf_text(user, node)
      bytes = Maker::FileBytes.read(user, node_id: node.node_id) # the port, via the preview shim
      return nil if bytes.blank?
      Tempfile.create([ "pdfmeta", ".pdf" ]) do |tmp|
        tmp.binmode
        tmp.write(bytes)
        tmp.flush
        Maker::PdfText.extract(tmp.path)
      end
    rescue FileLayer::FetchError, FileLayer::NotFound
      nil
    end

    # Fill blanks only. Tags are additive (union) since they aren't a single "blank" value.
    def apply(model, data)
      %i[designer license source_url].each do |f|
        model[f] = data[f] if model[f].blank? && data[f].present?
      end
      model.notes = data[:description] if model.notes.blank? && data[:description].present?
      model.print_settings = data[:print_settings] if model.print_settings.blank? && data[:print_settings].present?
      if data[:tags].present?
        model.tag_list = (model.tags.map(&:name) + data[:tags]).uniq.join(", ")
      end
      model.save!
    end
  end
end
