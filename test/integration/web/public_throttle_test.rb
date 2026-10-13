require "test_helper"

module Web
  # One per-IP budget over the whole anonymous surface (Public::BaseController). Every public
  # page is unauthenticated and does real work — a cover page enqueues renders, the byte route
  # streams a file through Puma on share — so a visitor who pays nothing per request can make the
  # box pay for all of them. The budget is far above a person (a page of sixty covers is 61
  # requests) and far below a scraper.
  #
  # THE COUNTER IS SHARED ACROSS TESTS (every request is 127.0.0.1); setup clears it.
  class PublicThrottleTest < ActionDispatch::IntegrationTest
    setup { ActionController::Base.cache_store.clear }

    test "an anonymous visitor past the per-minute budget is refused, not served" do
      budget = Public::BaseController::ANONYMOUS_REQUESTS_PER_MINUTE
      budget.times do
        get public_explore_path
        assert_response :success
      end
      get public_explore_path
      assert_response :too_many_requests
    end
  end
end
