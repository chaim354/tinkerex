module Projects
  # The wiring table's three write doors (stage 3, S3-3). Session-authed, like every Projects::*
  # controller. Create is nested under the project; update/destroy are shallow, like tasks and
  # bom_lines. Plain forms + redirects on success, no turbo_stream -- Projects::BomLinesController's
  # own reasoning applies here too: a connection is added or edited far less often than a task is
  # toggled, so there is no full-panel repaint worth avoiding.
  #
  # A REFUSAL KEEPS WHAT WAS TYPED (2026-11-02, the UX audit's B3): a refused create comes back as
  # the open composer with its error and fields (Projects::ComposerRefusal), and a refused row edit
  # as the table with that row still holding the typed values and its error beside them — 422 both,
  # where a redirect with an alert used to hand back an empty form.
  class ConnectionsController < ApplicationController
    include Projects::ComposerRefusal

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.connections.maximum(:position) || -1) + 1
      connection = project.connections.new(connection_params.merge(user: current_user, position: next_pos))
      if connection.save
        redirect_back_or_to project_path(project),
          notice: "Added #{connection.from_label} → #{connection.to_label}."
      else
        refuse_in_composer(project, id: "wiring-composer", partial: "projects/wiring_composer",
                           locals: { project:, draft: connection, error: refusal(connection) },
                           title: "Add a connection")
      end
    end

    # SCOPED TO THIS USER'S OWN CONNECTIONS, not a bare Maker::Connection.find -- a foreign id 404s
    # rather than letting one tenant edit another's row (CLAUDE.md §8).
    def update
      connection = current_user.maker_connections.find(params[:id])
      if connection.update(connection_params)
        redirect_back_or_to project_path(connection.project),
          notice: "Saved #{connection.from_label} → #{connection.to_label}."
      else
        refuse_row(connection)
      end
    end

    def destroy
      connection = current_user.maker_connections.find(params[:id])
      project = connection.project
      label = "#{connection.from_label} → #{connection.to_label}"
      connection.destroy!
      redirect_back_or_to project_path(project), notice: "Removed #{label}."
    end

    private

    def connection_params
      params.require(:connection).permit(:from_label, :to_label, :wire, :note)
    end

    def refusal(connection) = "Not added: #{connection.errors.full_messages.to_sentence}."

    # THE WHOLE TABLE, WITH THE REFUSED ROW AS TYPED. The row's fields live in the table and its form
    # outside it (projects/_wiring), so the panel is the smallest thing that can hold both; it takes
    # locals, so this needs no page behind it. The other rows render as saved — the refusal is about
    # this one, and the page never posted theirs.
    def refuse_row(connection)
      project = connection.project
      error = "Not saved: #{connection.errors.full_messages.to_sentence}."
      locals = { project:, connections: project.connections.to_a, editable: true, layout: project.panel_layout,
                 drafts: { connection.id => connection }, row_errors: { connection.id => error } }
      respond_to do |format|
        format.html do
          @project = project
          render "projects/composer_page", locals: { partial: "projects/wiring", locals:, title: "Wiring" },
                                           status: :unprocessable_entity
        end
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace("project-wiring", partial: "projects/wiring", locals:),
                 status: :unprocessable_entity
        end
      end
    end
  end
end
