require "test_helper"
require "support/public_fixture"

module Web
  # THE SHELL STARTS WITH A SKIP LINK (F onboarding, 2026-10-13). A keyboard user's first Tab walked
  # the whole rail (Recent, Library, every pinned folder and project) before it reached the page. The
  # link is the FIRST element in <body> on both of the layout's branches, and it targets main#main,
  # which both <main> elements carry.
  class SkipLinkTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as

    setup do
      @root = use_fresh_share_library!
    end

    test "the shell starts with a skip link that targets the main landmark" do
      sign_in_as(make_owner!(handle: "ada"))
      get root_path
      assert_response :success
      assert_select "body > a.skip-link[href='#main']:first-child", 1
      assert_select "main#main", 1
    end

    test "the signed-out shell has it too" do
      get new_user_session_path
      assert_response :success
      assert_select "body > a.skip-link[href='#main']:first-child", 1
      assert_select "main#main", 1
    end
  end
end
