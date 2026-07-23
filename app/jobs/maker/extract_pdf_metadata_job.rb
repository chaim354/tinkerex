require "tempfile"

module Maker
  # Parse a model's instructions PDF (via pdfium + Maker::PrintablesPdf) and fill only its EMPTY
  # fields. Best-effort, never overwrites what the user typed, idempotent (safe to re-run). Reads
  # the bytes via the FileLayer port for PROCESSING only — exactly as the preview jobs do — so no
  # sync/write path is touched (§10/§15 hold). Enqueued when an instructions PDF is attached.
  class ExtractPdfMetadataJob < ApplicationJob
    queue_as :default

    # A FetchError from reading the PDF is TRANSIENT (unmounted NAS, S3 5xx, creds blip) — retry
    # rather than silently forfeit the one-shot auto-fill, the same lesson GeneratePreviewJob
    # already encodes. NotFound (terminal) and everything else fall through as a no-op / loud
    # failure, deliberately.
    retry_on FileLayer::FetchError, wait: :polynomially_longer, attempts: 3

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
      return nil unless Maker::PdfText.available? # no pdfium -> skip the byte-read entirely
      bytes = Maker::FileBytes.read(user, node_id: node.node_id) # FetchError propagates to retry_on
      return nil if bytes.blank?
      Tempfile.create([ "pdfmeta", ".pdf" ]) do |tmp|
        tmp.binmode
        tmp.write(bytes)
        tmp.flush
        Maker::PdfText.extract(tmp.path)
      end
    rescue FileLayer::NotFound # terminal (deleted file) -> quiet no-op
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
