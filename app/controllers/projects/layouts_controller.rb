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
  #
  # A THIRD READ-ONLY HELPER JOINED THEM (2026-09-09, content blocks; spec §6): `preview` renders a
  # text block's Markdown. It is here rather than in a controller of its own because it is the same
  # thing the other two are — a conversion the editor asks for and nothing writes — and it is
  # project-scoped for the same reason they are: the door must be the owner's alone.
  class LayoutsController < ApplicationController
    include LayoutScoped
    # PREVIEW NEEDS THE PROJECT AND NOTHING ELSE: the shared filter also builds the folder listing,
    # a files query a Markdown render does not want to pay per keystroke (found in review).
    skip_before_action :set_project, only: :preview
    before_action :set_project_only, only: :preview

    def yaml
      doc = document
      result = doc.from_draft(parsed_draft)
      text = doc.to_yaml(result.ok? ? result.draft : doc.draft, project_name: @project.name)
      # A DRAFT THE DOCUMENT REFUSES STILL GETS SOME YAML, BUT NOT SILENTLY (found in review): the
      # text is the last saved layout, and its first line says why it is not the page on screen.
      text = "# The page holds an entry that cannot be saved yet (#{result.errors.first}); this is the last saved layout.\n#{text}" unless result.ok?
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

    # THE TEXT BLOCK'S PREVIEW (2026-09-09, content blocks; spec §6): the SAME Maker::Markdown both
    # pages render a block with, so what the maker sees while typing is what the page will show —
    # a second renderer here would be a preview that lies. 422 over the body cap rather than a
    # truncated render, for the same reason: a truncated preview says the block is shorter than it
    # is. Read-only, owner-scoped by LayoutScoped's `find_by!`, and it writes nothing.
    def preview
      markdown = params[:markdown].to_s
      return head :unprocessable_entity if markdown.bytesize > Maker::ProjectBlock::BODY_MAX

      render html: Maker::Markdown.render(markdown), content_type: "text/html"
    end

    private

    def set_project_only
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

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
