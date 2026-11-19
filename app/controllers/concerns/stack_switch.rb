# WHETHER A FILE LISTING DRAWS VERSION STACKS (Shop manual spec §9): ON unless the maker turned them
# off with the "Stack versions and backups" box. One answer for the Library (FilesController) and
# Search (SearchController), because "show me versions as one" is one choice about file listings,
# not one per page. The project page's switch is per panel and saved on the project row instead
# (Projects::PanelsController#update_stack), as a panel's view is.
#
# THE SAME WHITELIST-AND-COOKIE IDIOM AS FilesController#resolve_hidden, and for its reason: the
# choice has to survive clicking into a folder, and folder links carry only `folder:`. A cookie the
# SERVER reads, never browser storage, so the first render is already the right one (rule 7's
# argument for the theme). `?stacks=0` and `?stacks=1` set it; anything else reads it; only the two
# values are ever written, so a hand-edited `?stacks=banana` persists nothing.
module StackSwitch
  extend ActiveSupport::Concern

  STACK_VALUES = %w[0 1].freeze

  private

  def resolve_stacks
    requested = params[:stacks].presence
    if STACK_VALUES.include?(requested)
      cookies[:files_stacks] = { value: requested, expires: 1.year }
      return requested == "1"
    end
    cookies[:files_stacks] != "0"
  end
end
