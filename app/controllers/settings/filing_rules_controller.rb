module Settings
  # The extension map the intake sweep files by (stage 3, S3-1) -- a flat reference list with an
  # inline add, an inline per-row folder edit and a Remove, in the shape of Suppliers/Locations
  # (session-authed web layer, §14d -- not the device-token v1 API, which has none of this).
  # Removing a rule never breaks anything downstream: an extension with no rule simply files into
  # "other" (Maker::ProjectFolders.folder_for), the same answer it gets if it was never seeded.
  class FilingRulesController < ApplicationController
    def index
      Maker::FilingRules.seed!(current_user)
      @rules = current_user.maker_filing_rules.order(:ext)
    end

    def create
      rule = current_user.maker_filing_rules.new(filing_rule_params)
      if rule.save
        redirect_to settings_filing_rules_path, notice: "Filing rule for .#{rule.ext} added."
      else
        redirect_to settings_filing_rules_path, alert: rule.errors.full_messages.to_sentence
      end
    end

    # FOLDER ONLY -- the extension is what every other row is keyed by (the unique index is
    # `(user_id, ext)`), so changing it here would either collide with another row or silently
    # orphan this one's identity. Renaming an extension's rule is Remove-then-add, same as Tags
    # offers no rename either.
    #
    # SCOPED THROUGH current_user, NEVER Maker::FilingRule.find -- a foreign id must 404, not
    # resolve another user's row (the same argument SuppliersController#destroy makes).
    def update
      rule = current_user.maker_filing_rules.find(params[:id])
      if rule.update(params.require(:filing_rule).permit(:folder))
        redirect_to settings_filing_rules_path, notice: "Filing rule for .#{rule.ext} updated."
      else
        redirect_to settings_filing_rules_path, alert: rule.errors.full_messages.to_sentence
      end
    end

    # SCOPED THROUGH current_user, NEVER Maker::FilingRule.find -- a foreign id must 404, not
    # resolve another user's row. Mutation-checked (this task's step 4).
    def destroy
      rule = current_user.maker_filing_rules.find(params[:id])
      rule.destroy!
      redirect_to settings_filing_rules_path, notice: "Filing rule for .#{rule.ext} removed."
    end

    private

    def filing_rule_params
      params.require(:filing_rule).permit(:ext, :folder)
    end
  end
end
