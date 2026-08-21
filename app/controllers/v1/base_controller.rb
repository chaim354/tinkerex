module V1
  # STAGE 3b PHASE B TASK 7: this class's ENTIRE former body -- `include Authentication`,
  # `include LibraryCapabilities`, and the five generic JSON rescue_froms -- moved to
  # `Sync::V1::BaseController` (the tinkerex-sync gem, app/controllers/sync/v1/base_controller.rb),
  # which this class now inherits from rather than reimplementing. See that class's own header
  # comment for the three-option decision and the argument for this one; the short version is
  # that the alternative (this engine's twelve controllers inheriting a HOST-defined base) makes
  # `Sync::V1::ChangesController` and friends unloadable without this app present, the wrong
  # direction for a gem this whole arc's goal is to make sellable standalone.
  #
  # STAYS A REAL CLASS, NOT A BARE ALIAS (`BaseController = Sync::V1::BaseController`), for the
  # same reason Stage 3a Task 5 gave for splitting rescues down to their actual raisers: this is
  # the ONE class all fourteen v1/maker/* controllers inherit from, and it is where a HOST-ONLY
  # addition (a maker-specific rescue, a maker-specific before_action) would go if one is ever
  # needed -- exactly the shape DevicesController already uses today
  # (`skip_before_action :authenticate_device!, only: :login`), which still works unchanged here
  # because Rails' callback chain is inherited regardless of which ancestor registered the filter.
  class BaseController < Sync::V1::BaseController
  end
end
