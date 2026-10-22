module Tools
  # THE CALCULATOR'S SIDEBAR PIN (2026-10-21; docs/superpowers/plans/2026-10-21-calculator-modal.md,
  # decision 1). The Tools gallery's Calculator card posts here; the rail reads
  # `current_user.calculator_pinned?` and shows a Calculator link that opens the modal. A user
  # column, so the pin follows the maker to every device; the rail's collapse state is a per-browser
  # cookie because it is about the screen, not the person.
  #
  # NOT A Tools::BaseController: that base exists for the addon doors that write into the library,
  # and this writes one flag on the user.
  class CalculatorPinsController < ApplicationController
    def create
      set_pinned(true)
      redirect_back_or_to tools_path, notice: "Calculator pinned to the sidebar."
    end

    def destroy
      set_pinned(false)
      redirect_back_or_to tools_path, notice: "Calculator unpinned from the sidebar."
    end

    private

    # `update_column`, NOT `update!`: a display preference must not be refused by validations that
    # have nothing to do with it. A legacy row whose handle a later RESERVED_HANDLES entry now
    # excludes (`calculations` joined that list with this feature) would otherwise fail every pin
    # with a 500 about a field the maker never touched.
    def set_pinned(value)
      current_user.update_column(:calculator_pinned, value)
    end
  end
end
