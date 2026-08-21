require "test_helper"

# THE GUARD THE ROUTING FIX EXISTS FOR.
#
# Stage 3b Phase B moved every Sync::V1::* controller into the engine and left the routing in this
# app's config/routes.rb. Task 9's dummy host then needed the same routes and hand-copied 26 of
# them, with its own file saying so out loud: "It is NOT auto-generated and NOT shared with the host
# file -- the two can drift, which is the gap itself."
#
# Both now call Sync.draw_v1_routes. This asserts that actually took: every path the engine defines
# is really reachable in THIS app. Without it, "they share a definition" is a claim about a method
# call rather than about the route table, and a drawer that silently drew nothing would look
# identical from the outside.
class EngineRoutesTest < ActiveSupport::TestCase
  # Draw the engine's own routes into a throwaway set and read back what they produced. Asking the
  # DRAWER rather than hard-coding a list is the whole point: a list here would be the third copy of
  # the thing this test exists to stop there being two of.
  def engine_paths
    set = ActionDispatch::Routing::RouteSet.new
    set.draw { namespace(:v1) { Sync.draw_v1_routes(self) } }
    set.routes.map { |r| [ r.verb, r.path.spec.to_s.sub(/\(\.:format\)\z/, "") ] }.sort
  end

  def app_paths
    Rails.application.routes.routes
         .map { |r| [ r.verb, r.path.spec.to_s.sub(/\(\.:format\)\z/, "") ] }.to_set
  end

  test "every route the engine defines is drawn by this app" do
    missing = engine_paths.reject { |verb, path| app_paths.include?([ verb, path ]) }
    assert_empty missing,
                 "the engine defines routes this app never draws -- Sync.draw_v1_routes is either " \
                 "not called or called somewhere its output does not land: #{missing}"
  end

  # The count is asserted as a RELATIONSHIP to the drawer, never as a literal. A literal would have
  # to be edited every time the engine adds a route, which is exactly the manual step the drawer
  # removed -- and an out-of-date literal fails for the wrong reason.
  test "the engine actually defines routes, so the test above cannot pass vacuously" do
    assert_operator engine_paths.size, :>, 20,
                    "Sync.draw_v1_routes drew almost nothing -- if the drawer is empty, the " \
                    "assertion above passes trivially and proves nothing"
  end

  # EVERY ENGINE ROUTE TARGETS AN ENGINE CONTROLLER. The leading `/` on each `to:` is what makes
  # that work: inside `namespace :v1` an unqualified "commits#create" resolves against that
  # namespace and looks for V1::CommitsController, which has not existed since Phase B. Getting this
  # wrong produces a routing error at request time, not at boot, so it is worth pinning here.
  test "the engine's routes all target sync/v1 controllers" do
    set = ActionDispatch::Routing::RouteSet.new
    set.draw { namespace(:v1) { Sync.draw_v1_routes(self) } }
    strays = set.routes.map { |r| r.defaults[:controller] }.compact.uniq.reject { |c| c.start_with?("sync/v1/") }
    assert_empty strays, "engine routes pointing outside sync/v1 -- a missing leading `/` on `to:`: #{strays}"
  end
end
