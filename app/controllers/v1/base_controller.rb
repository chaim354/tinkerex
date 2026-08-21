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
  # STANDS ON ActionController::API, NOT ON Sync::V1::BaseController, since 2026-08-21.
  #
  # It DID inherit the engine's base -- Stage 3b Phase B Task 7's deliberate direction, so that all
  # fourteen v1/maker/* controllers rode the same v1 infrastructure the engine's own twelve did.
  # That direction is still right FOR THE ENGINE (§14j: an engine inheriting a host class cannot
  # load in a bare mount). It is simply not survivable in the other direction: a superclass is
  # resolved when this class body loads, so on share/s3 -- where the engine is not in the process at
  # all -- the maker app's own API had no base class and the app could not eager-load.
  #
  # WHAT IT DELIBERATELY DOES NOT INCLUDE: Sync::V1::CapabilityGate. Checked, not assumed -- no
  # controller under app/controllers/v1/ calls `require_capability!`. That gate answers "does this
  # deployment's backend support this SYNC operation", a question only the engine's own endpoints
  # ask. Copying it here would import a dependency to serve no caller.
  class BaseController < ActionController::API
    include ::V1::Authentication

    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActionController::ParameterMissing, with: :bad_request
    rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
    rescue_from ArgumentError, with: :unprocessable
    rescue_from ActiveRecord::RecordNotUnique, with: :conflict

    private

    def not_found(_e) = render(json: { error: "not_found" }, status: :not_found)
    def bad_request(e) = render(json: { error: e.message }, status: :bad_request)
    def unprocessable(e) = render(json: { error: e.message }, status: :unprocessable_entity)
    def conflict(e) = render(json: { error: e.message }, status: :conflict)
  end
end
