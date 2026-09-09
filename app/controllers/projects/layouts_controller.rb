module Projects
  # THE DRAWER'S TWO CONVERSIONS (2026-09-09, the page editor; spec §5). Both are READ-ONLY: a draft
  # in, YAML out; YAML in, a draft plus notes and errors out. Neither touches the column — Save is
  # PanelsController#update's document branch — and Maker::LayoutDocument is the one grammar the
  # three share, which is why the browser never parses or emits YAML itself (spec decision 2).
  #
  # `parse` ANSWERS 200 WITH ERRORS, deliberately: the browser shows them beside the text, and a
  # 4xx would read as the endpoint failing rather than the text. `yaml` for a draft that does not
  # validate answers the CURRENT layout's text rather than an error, because the only way to send
  # one is by hand, and the honest answer to "show me the YAML" is still some YAML.
  class LayoutsController < ApplicationController
    include LayoutScoped

    def yaml
      doc = document
      result = doc.from_draft(parsed_draft)
      text = doc.to_yaml(result.ok? ? result.draft : doc.draft, project_name: @project.name)
      render plain: text, content_type: "text/plain"
    end

    # THE BASE IS THE BROWSER'S DRAFT, NOT THE SAVED ROW (found by the browser suite): a hide made
    # with the eye a moment ago must survive an Apply whose text does not name that panel. The draft
    # is validated through #from_draft first, so a hand-made or missing one falls back to the row.
    def parse
      doc = document
      base = doc.from_draft(parsed_draft)
      result = doc.parse(params[:yaml].to_s, base: base.ok? ? base.draft : nil)
      render json: { draft: result.draft, notes: result.notes, errors: result.errors }
    end

    private

    # `params[:draft]` IS A STRING FROM A FORM FIELD AND Parameters FROM A JSON POST, and both must
    # work: the editor posts JSON, the integration test posts a form field.
    # A MISSING `draft` ANSWERS nil RATHER THAN RAISING: `nil.to_unsafe_h` is a 500 on a request a
    # browser of ours never sends, and #from_draft already answers "not a layout draft" for nil.
    def parsed_draft
      raw = params[:draft]
      return JSON.parse(raw) if raw.is_a?(String)

      raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : nil
    rescue JSON::ParserError
      nil
    end
  end
end
