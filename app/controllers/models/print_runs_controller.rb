module Models
  # Log a print against a model / delete a logged print. The Maker::PrintRun after_save/destroy
  # callback keeps the model's print_status in sync (latest run wins).
  class PrintRunsController < ApplicationController
    before_action :authenticate_user!

    # POST /models/:model_id/print_runs
    def create
      model = current_user.maker_models.find_by!(slug: params[:model_id])
      run = model.print_runs.build(run_params.merge(user: current_user))
      if run.save
        redirect_to model_path(model), notice: "Logged a print."
      else
        redirect_to model_path(model), alert: run.errors.full_messages.to_sentence
      end
    end

    # DELETE /print_runs/:id (shallow)
    def destroy
      run = current_user.maker_print_runs.find(params[:id])
      model = run.model
      run.destroy!
      redirect_to model_path(model), notice: "Removed the print."
    end

    private

    def run_params
      params.require(:print_run).permit(:printed_on, :printer, :material, :outcome,
                                        :duration_hours, :filament_grams, :notes)
    end
  end
end
