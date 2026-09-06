module Projects
  # The wiring table's three write doors (stage 3, S3-3). Session-authed, like every Projects::*
  # controller. Create is nested under the project; update/destroy are shallow, like tasks and
  # bom_lines. Plain forms + redirects, no turbo_stream -- Projects::BomLinesController's own
  # reasoning applies here too: a connection is added or edited far less often than a task is
  # toggled, so there is no full-panel repaint worth avoiding.
  class ConnectionsController < ApplicationController
    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.connections.maximum(:position) || -1) + 1
      connection = project.connections.new(connection_params.merge(user: current_user, position: next_pos))
      if connection.save
        redirect_back_or_to project_path(project),
          notice: "Added #{connection.from_label} → #{connection.to_label}."
      else
        redirect_back_or_to project_path(project), alert: connection.errors.full_messages.to_sentence
      end
    end

    # SCOPED TO THIS USER'S OWN CONNECTIONS, not a bare Maker::Connection.find -- a foreign id 404s
    # rather than letting one tenant edit another's row (CLAUDE.md §8).
    def update
      connection = current_user.maker_connections.find(params[:id])
      if connection.update(connection_params)
        redirect_back_or_to project_path(connection.project), notice: "Saved."
      else
        redirect_back_or_to project_path(connection.project), alert: connection.errors.full_messages.to_sentence
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
  end
end
