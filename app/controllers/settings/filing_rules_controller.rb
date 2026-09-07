module Settings
  # The extension map the intake sweep files by (stage 3, S3-1) -- session-authed web layer, §14d,
  # not the device-token v1 API, which has none of this.
  # Removing a rule never breaks anything downstream: an extension with no rule simply files into
  # "other" (Maker::ProjectFolders.folder_for), the same answer it gets if it was never seeded.
  #
  # ONE CARD PER FOLDER SINCE STAGE 4, S4-2 (story 4.3). The flat 124-row table was a correct
  # reference and an unusable page: a maker asks "where does laser work go", and the answer was
  # spread over four screens. Same rows, same routes, same actions -- the GROUPING is the change.
  #
  # #update SURVIVES WITH NO CONTROL ON THE PAGE, AND THAT IS DELIBERATE, NOT AN OVERSIGHT. The
  # card layout carries an extension and a Remove per chip; moving `.dxf` from design/ to laser/ is
  # Remove there, Add here -- two clicks on a rare action, against a per-chip folder picker on all
  # 124 chips. The action, its route and its tests stay because the row-level edit is a real verb a
  # later control can reach for, and dropping a working action to match today's markup is how a
  # route comes back subtly different.
  class FilingRulesController < ApplicationController
    def index
      Maker::FilingRules.seed!(current_user)
      # ONE QUERY, GROUPED IN MEMORY. A card per folder over `where(folder:)` would be eleven-plus
      # queries for a page whose whole content is one small table -- page_query_budget_test.rb pins
      # this against the number of FOLDERS, which is the axis that grows here (its older case grows
      # rules inside ONE folder and cannot see a per-card query at all).
      @rules = current_user.maker_filing_rules.order(:ext).to_a
      @by_folder = @rules.group_by(&:folder)
      # DERIVED, NEVER A LITERAL LIST. `ROLE_FOLDERS.values.uniq` is the eleven folders the seed can
      # produce, in the vocabulary's own order (`docs` and `cnc` each answer for two roles and
      # appear once); a folder a maker typed at this very form is appended after them, so a rule
      # they made is always visible somewhere. S4-2 added a role and this line needed no edit.
      @folders = (Maker::ProjectFolders::ROLE_FOLDERS.values + @by_folder.keys).uniq
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
