require "test_helper"
require "yaml"
require "support/public_fixture"

module Web
  # THE COMPOSE GENERATOR AT THE REQUEST LEVEL (/install/compose, 2026-10-21). What a request can see:
  # that the page answers a visitor on every deployment with no redirect to sign-in, renders the same
  # visitor's page for a signed-in owner, carries the template the browser builds from, and has NO
  # FORM -- the page's privacy rule, since a form is the one element that would put a typed password
  # into a URL. The building itself is the browser's (test/system/compose_generator_test.rb).
  class ComposeGeneratorTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as

    setup do
      @root = use_fresh_share_library!
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    teardown do
      @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo
    end

    def template_value
      JSON.parse(css_select("[data-controller~=compose]").first["data-compose-template-value"])
    end

    test "a visitor gets the page with no sign-in, on a self-hosted box and on the public demo's" do
      [ nil, "demo@example.com" ].each do |demo|
        demo ? ENV["DEMO_ACCOUNT_EMAIL"] = demo : ENV.delete("DEMO_ACCOUNT_EMAIL")
        get public_compose_path
        assert_response :success, "demo #{demo.inspect}"
        assert_equal "/install/compose", public_compose_path
        assert_select "h1", text: "Make a docker-compose.yml"
        assert_select "main#main.container.public-main", 1
        assert_select ".public-header .public-intro", text: /written in this browser tab/
        assert_select "button.btn.primary", { count: 1, text: "Download" }, "Download is the page's one accent"
      end
    end

    test "a signed-in owner sees the same visitor's page, not the app's shell" do
      sign_in_as(make_owner!(handle: "maker"))
      get public_compose_path
      assert_response :success
      assert_select ".rail", 0
      assert_select ".public-header", 1
      assert_select "[data-controller~=compose]", 1
    end

    # THE PRIVACY RULE, AS MARKUP. Enter in a field inside a form submits it, and a GET form puts the
    # values in the query string -- an SMB password in a URL, a server log and the browser history.
    # The page must hold no form at all, the layout's included. Mutation-checked: an empty <form>
    # added to the view goes red here.
    test "the page has no form, so nothing typed into it can be submitted" do
      get public_compose_path
      assert_select "form", 0
      assert_select "[data-controller~=compose] input[name=sharePassword][type=password]", 1
      assert_select "[data-controller~=compose] input[name=smtpPassword][type=password]", 1
    end

    test "the page carries the template derived from docker-compose.yml, and the install guide's address" do
      get public_compose_path
      template = template_value
      assert_equal YAML.safe_load(Rails.root.join("docker-compose.yml").read), template["tree"]
      assert_equal %w[boxes openscad addons], template.dig("tools", "services")
      assert_equal "library", template.dig("share", "volume")
      assert_select "[data-compose-guide-value=?]", Tinkerex::Landing::INSTALL_URL
    end

    # Every message the browser can write has a slot, named for the input it is about; an input the
    # controller reads by name must exist, or its message would never show.
    test "every validated input has its message slot" do
      get public_compose_path
      %w[folderPath shareServer shareName shareUser sharePassword shareVersion puid pgid port tag smtpAddress appHost smtpPort smtpAuthentication].each do |name|
        assert_select "[name=#{name}]", 1
        assert_select "[data-compose-error=#{name}][hidden]", 1
      end
    end

    # THE LINKS. INSTALL.md points at the generator on the public demo's own host, read from the deploy
    # config that names it, so a moved route or host breaks this rather than the guide's link.
    test "the landing and INSTALL.md's quick start both link the generator" do
      host = YAML.safe_load(Rails.root.join("config/deploy.ovh.yml").read, aliases: true).dig("proxy", "hosts").first
      assert_equal "tinkerex.com", host
      quick_start = Rails.root.join("docs/INSTALL.md").read[/^## 2\. Quick start\n.*?(?=^## 3\.)/m]
      assert quick_start, "INSTALL.md has no section 2, Quick start"
      assert quick_start.include?("https://#{host}#{public_compose_path}"),
             "INSTALL.md's quick start does not link https://#{host}#{public_compose_path}"

      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      get "/"
      assert_select ".landing-footer a[href=?]", public_compose_path
      assert_select ".landing-closing a.btn:not(.primary)[href=?]", public_compose_path
    end
  end
end
