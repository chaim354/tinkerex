module Models
  # Log a print against a model / delete a logged print. The Maker::PrintRun after_save/destroy
  # callback keeps the model's print_status in sync (latest run wins).
  #
  # EVERY SUCCESS REDIRECTS BACK (structural redesign §5.4, slice 5), so a print logged from the
  # Library's model strip stays in that folder; with no usable referer it lands on the model page,
  # exactly as it always did.
  #
  # A REFUSAL RE-RENDERS THE MODEL PAGE (UX audit 2026-11-01, B3): 422, Details open, the composer
  # open with its errors and what was typed. It used to redirect back with an alert, which dropped
  # every field. From the strip that means landing on the model's own page rather than the folder —
  # the one page that can show this form with its errors, and the price of keeping the input.
  class PrintRunsController < ApplicationController
    include Models::Page

    # POST /models/:model_id/print_runs
    def create
      @model = current_user.maker_models.find_by!(slug: params[:model_id])
      run = @model.print_runs.build(run_params.merge(user: current_user))
      if run.save
        redirect_back_or_to model_path(@model), notice: "Logged a print."
      else
        @model.print_runs.reset
        load_model_stage("details")
        load_model_files
        @print_run_draft = run
        @print_log_open = true
        render "models/show", status: :unprocessable_entity
      end
    end

    # DELETE /print_runs/:id (shallow)
    def destroy
      run = current_user.maker_print_runs.find(params[:id])
      model = run.model
      run.destroy!
      redirect_back_or_to model_path(model), notice: "Deleted the print."
    end

    private

    def run_params
      params.require(:print_run).permit(:printed_on, :printer, :material, :outcome,
                                        :duration_hours, :filament_grams, :notes)
    end
  end
end
