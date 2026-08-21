# frozen_string_literal: true

require "test_helper"

# THE ONLY SUITE THAT RUNS WITH THE SYNC ENGINE GENUINELY ABSENT (`bin/ci test-no-engine`:
# LIBRARY_BACKEND=share SYNC_ENGINE=0).
#
# The three backend legs deliberately set SYNC_ENGINE=1 so their counts stay identical and §15's
# ambient-backend guard survives. That leaves this file as the ONLY executor of the conditional
# load in config/application.rb -- and a conditional nobody runs is CLAUDE.md §14a's recorded bug:
# a boot guard that passed the whole suite and took production down.
#
# IT ASSERTS ABSENCE, WHICH IS THE HARD DIRECTION. `assert_not defined?(Sync)` passes just as well
# in a process where the engine failed to load for some unrelated reason, so each absence assertion
# is paired with a POSITIVE one showing the app is otherwise working -- the library renders, an
# upload round-trips. Absence alone would be satisfied by a broken app.
class NoEngineBootTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct horse battery staple".freeze

  # THE SKIP KEYS ON WHETHER THIS LEG WAS INVOKED, NEVER ON `defined?(Sync)`, AND THE DIFFERENCE
  # IS THE WHOLE GUARD. The first version skipped when Sync was defined -- so a mutation making
  # `LibraryBackend.engine_wanted?` return true unconditionally, which is exactly the regression
  # this file exists to catch, loaded the engine, skipped every test here, and reported SUCCESS.
  # Mutation-checked and found green; that is how this comment came to exist.
  #
  # Keyed on the ENV var instead, the same mutation now RUNS these tests and fails on the first
  # assertion, because "the engine is absent" is the claim rather than the precondition.
  setup do
    skip "runs only under `bin/ci test-no-engine`" unless ENV["SYNC_ENGINE"] == "0"
  end

  # This suite creates its own user rather than reaching for a fixture: there is no
  # test/fixtures/users.yml in this repo, and every web integration test does the same.
  def sign_in(email = "no-engine@example.com")
    user = User.find_by(email:) || User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email:, password: PASSWORD } }
    user
  end

  test "the engine is not in the process at all" do
    assert_not defined?(Sync), "Sync is defined -- the conditional require did not take"
    assert_not LibraryBackend.engine_wanted?, "engine_wanted? is true with SYNC_ENGINE=0"
  end

  test "the app still serves its library, which is what makes the absence meaningful" do
    sign_in
    get files_path
    assert_response :success
  end

  test "the port answers, and it is the share adapter" do
    assert_equal "FileLayer::Share", FileLayer.current.class.name
    assert FileLayer.current.capabilities.port_writable?, "share must still take uploads"
    assert_not FileLayer.current.capabilities.syncable?, "share is not syncable, engine or no engine"
  end

  test "the maker v1 API has a base class and it is not the engine's" do
    # The reason this arc needed a design change rather than a guard: a superclass is resolved when
    # the class body loads, so `V1::BaseController < Sync::V1::BaseController` made all fourteen
    # v1/maker/* controllers unloadable here.
    assert_equal ActionController::API, V1::BaseController.superclass
    assert V1::BaseController.include?(::V1::Authentication)
  end

  test "the engine's own v1 routes are absent rather than merely gated" do
    # On a backend that loads the engine these 501. With no engine in the process there is no
    # controller to reach, so the honest answer is that the route does not exist.
    #
    # DRIVEN AS A REAL REQUEST, not asserted with `assert_raises`: `config.action_dispatch
    # .show_exceptions` is `all` here, so a missing route RENDERS a 404 rather than raising, and
    # the raise-shaped assertion fails for a reason that has nothing to do with the engine. The
    # router agrees either way -- `recognize_path("/v1/tree")` does raise -- but §15 is explicit
    # that `recognize_path` is the wrong instrument when a real request can be driven instead.
    get "/v1/tree"
    assert_response :not_found
  end

  test "a user can be destroyed, which the Sync:: associations used to prevent" do
    # `class_name:` is lazy, but `dependent: :destroy` constantizes -- probed, not reasoned. This
    # raised `Missing model class Sync::Version` from an ordinary destroy before user.rb's
    # associations became conditional, and nothing at boot showed it.
    u = User.create!(email: "destroyable@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert_nothing_raised { u.destroy! }
  end

  test "the recurring schedule names no constant this process cannot resolve" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"))["production"] || {}
    unresolvable = schedule.filter_map { |name, cfg|
      klass = cfg["class"]
      name if klass && klass.safe_constantize.nil?
    }
    assert_empty unresolvable,
                 "recurring.yml entries whose `class:` cannot resolve without the engine -- Solid " \
                 "Queue resolves these at load, so each one is a scheduler crash: #{unresolvable}"
  end
end
