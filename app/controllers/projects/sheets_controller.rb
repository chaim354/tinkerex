module Projects
  # Free-form project spreadsheets. Backend-neutral: sheets are app-DB maker rows, so this
  # controller never touches the file layer port or the sync/chunk-store machinery — nothing here
  # is capability-gated and every action behaves identically on chunk, share and s3.
  # (Worded to avoid the literal tokens Task 6's tripwire grep matches on — see CLAUDE.md §10 and
  # its "a proof that cries wolf gets ignored" lesson: a comment merely NAMING what this file
  # avoids would itself trip that grep and read as a false positive.)
  class SheetsController < ApplicationController
    before_action :set_sheet, only: %i[show update destroy]

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.sheets.maximum(:position) || -1) + 1
      sheet = project.sheets.create!(
        user: current_user,
        name: params.dig(:sheet, :name).presence || "Sheet #{project.sheets.count + 1}",
        position: next_pos,
        data: Maker::Sheet.blank_data
      )
      redirect_to sheet_path(sheet)
    end

    def show
      respond_to do |format|
        format.html
        format.csv do
          send_data @sheet.to_csv, type: "text/csv",
                    filename: "#{@sheet.name.parameterize.presence || 'sheet'}.csv",
                    disposition: "attachment"
        end
      end
    end

    # Two callers, one action: the grid's debounced JSON autosave (sends `data`) and the rename
    # form (sends `name`). Answering by format keeps them from needing separate routes.
    #
    # THE RESCUE IS NOT DECORATION. `update!` on an over-limit blob raises RecordInvalid, which for
    # the autosave means a 500 the debounced fetch shows as NOTHING — trading unbounded growth for a
    # save that fails silently while the user keeps typing. The JSON branch answers 422 with the
    # message so the status indicator's error state can say it.
    def update
      @sheet.update!(sheet_params)
      respond_to do |format|
        format.json { render json: { status: "ok", updated_at: @sheet.updated_at } }
        format.html { redirect_to sheet_path(@sheet) }
      end
    rescue ActiveRecord::RecordInvalid => e
      respond_to do |format|
        format.json { render json: { status: "error", error: e.record.errors.full_messages.to_sentence },
                             status: :unprocessable_entity }
        format.html { redirect_to sheet_path(@sheet), alert: e.record.errors.full_messages.to_sentence }
      end
    end

    def destroy
      project = @sheet.project
      @sheet.destroy!
      redirect_to project_path(project), notice: "Sheet deleted."
    end

    private

    def set_sheet
      @sheet = current_user.maker_sheets.find(params[:id])
    end

    # `data` is an arbitrary nested structure the grid round-trips, so it is permitted whole rather
    # than shape-checked here — Maker::Sheet's readers are what defend the render against a
    # malformed blob.
    def sheet_params
      params.require(:sheet).permit(:name, :position, data: {})
    end
  end
end
