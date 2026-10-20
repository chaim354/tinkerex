require "test_helper"

module V1
  # A BARE ArgumentError FROM A v1 ACTION IS A PROGRAMMING ERROR, SO IT ANSWERS 500 (F-S18-1,
  # 2026-10-19). V1::BaseController carried `rescue_from ArgumentError, with: :unprocessable` from
  # the sync engine, written for three of its raisers (a malformed manifest hash, a move cycle, a
  # foreign conflict version) that left this app with the engine. What it caught after that was
  # arity drift, a renamed keyword and a misconfigured backend -- each answered 422, "your request
  # was invalid", with the interpreter's message in the body and nothing reported as an error. A
  # client-input ArgumentError a future action really has gets a NAMED SUBCLASS and its own
  # rescue_from (Maker::MoveNode::InvalidName is the precedent); architecture_invariants_test.rb
  # pins that no controller rescues the bare class again.
  class BaseControllerErrorsTest < ActionDispatch::IntegrationTest
    # The interpreter's own wording for one keyword drift an action could hit.
    MESSAGE = "unknown keyword: :version_id".freeze

    # The house stub helper (device_login_test.rb) on the INSTANCE side, because an action is an
    # instance method of its controller; Minitest 6 has no Object#stub. An inherited method is
    # removed afterwards rather than left shadowed.
    def replacing(owner, name, replacement)
      own = owner.instance_methods(false).include?(name)
      original = owner.instance_method(name)
      owner.define_method(name, &replacement)
      yield
    ensure
      own ? owner.define_method(name, original) : owner.remove_method(name)
    end

    # PRODUCTION'S EXCEPTION RENDERING, NOT THE TEST ENV'S. test.rb's show_exceptions = :rescuable
    # RAISES an unmapped error into the test, and consider_all_requests_local = true renders one as
    # the debug page, message included; production renders PublicExceptions' bare 500. Both keys are
    # restored, or every later test in this worker inherits them.
    def as_in_production
      config = Rails.application.env_config
      saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
      config.merge!("action_dispatch.show_exceptions" => :all, "action_dispatch.show_detailed_exceptions" => false)
      yield
    ensure
      config.merge!(saved) if saved
    end

    # STATUS FIRST, then the body, then the report: a 500 that still sends the message, or one the
    # error tracker never hears about, is each the old 422's defect under a new status code.
    test "an ArgumentError an action raises answers 500 and is reported, never 422 with its message" do
      token = bootstrap_token(email: "argument-error@example.com")
      reports = as_in_production do
        replacing(V1::Maker::TagsController, :index, -> { raise ArgumentError, MESSAGE }) do
          capture_error_reports(ArgumentError) do
            get "/v1/maker/tags", headers: { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
          end
        end
      end

      assert_response :internal_server_error
      assert_not_includes response.body, MESSAGE, "the interpreter's message must never reach the client"
      assert_equal [ MESSAGE ], reports.map { |report| report.error.message },
                   "the error must reach Rails.error as unhandled, or no error tracker ever sees it"
    end
  end
end
