require "application_system_test_case"

# THE LANDING IN A BROWSER (second pass, 2026-10-16). What a request test cannot see: that
# `landing-main` beats the layout's 440px auth column (a computed width), that the wall stands beside
# the pitch on a desktop and under it on a phone, that every tile actually LOADED (an <img> whose
# bytes do not decode is a broken box a request test passes over), and that nothing scrolls sideways
# at 375px (design-system.md rule 11). The viewport is set through CDP: headless Chrome refuses a
# window narrower than 500px.
class LandingSystemTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    User.create!(email: "demo@example.com", password: SecureRandom.base58(32), confirmed_at: Time.current, handle: "demo")
  end

  teardown do
    @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def rect(selector)
    page.evaluate_script("(r => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }))" \
                         "(document.querySelector(#{selector.to_json}).getBoundingClientRect())")
  end

  test "the wall stands beside the pitch at desktop width, every tile loads, and a phone stacks it without sideways scroll" do
    visit "/"
    assert_selector ".landing-hero h1"
    assert_selector ".landing-wall img", count: Tinkerex::Landing::TILES.size

    width = rect("main#main")["width"]
    assert_operator width, :>, 900, "main is #{width}px wide: the landing is still inside the 440px auth column"
    assert_operator rect(".landing-pitch")["right"], :<=, rect(".landing-wall")["left"],
                    "the wall should stand right of the pitch at desktop width"

    # LOADED, NOT MERELY PRESENT: a tile whose bytes do not decode has naturalWidth 0.
    widths = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const imgs = [...document.querySelectorAll('.landing-wall img')];
      Promise.all(imgs.map(i => i.complete ? null : new Promise(r => { i.onload = i.onerror = r })))
        .then(() => done(imgs.map(i => i.naturalWidth)));
    JS
    assert widths.all?(&:positive?), "a wall tile did not load: naturalWidths #{widths.inspect}"

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit "/"
      assert_selector ".landing-hero h1"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
             "the landing scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      assert_operator rect(".landing-wall")["top"], :>=, rect(".landing-pitch")["bottom"],
                      "the wall should stack under the pitch on a phone"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  # THE DOOR (Shop manual slice 8; users/shared/_door, the `sign-in` screen). Every signed-out Devise
  # page stands in two halves at desktop width: the product's name and its figure LEFT of the page's
  # boxes, the Sign in box on the first screen. On a phone the halves stack, the figure leaves so the
  # form reaches the first screen, and nothing scrolls sideways (design-system.md rule 11). Demo mode
  # is on here (the setup), so the demo's box stands above the form, as it does on the public box.
  # Mutation-checked (2026-11-19), each red line as it printed: `.auth-card { display: block }` gave
  # "the intro should stand left of the boxes at desktop width"; dropping `.auth-figure` from the
  # 899px `display: none` gave `expected not to find visible css ".auth-figure", found 1 match`;
  # `white-space: nowrap` on `.auth-slogan` gave "the door scrolls sideways at 375px (scrollWidth 574)".
  test "the sign-in door stands its intro beside its boxes at desktop width, and stacks on a phone" do
    visit new_user_session_path
    assert_selector ".auth-card .auth-box h1", text: /\Asign in\z/i
    assert_selector ".auth-card .demo-entry"
    assert_operator rect(".auth-intro")["right"], :<=, rect(".auth-forms")["left"] + 1,
                    "the intro should stand left of the boxes at desktop width"
    assert_selector ".auth-figure img", visible: true
    assert_operator rect(".auth-box")["bottom"], :<=, page.evaluate_script("window.innerHeight"),
                    "the Sign in box should be on the first screen"

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit new_user_session_path
      assert_selector ".auth-card .auth-box h1", text: /\Asign in\z/i
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
             "the door scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      assert_operator rect(".auth-forms")["top"], :>=, rect(".auth-intro")["bottom"] - 1,
                      "the boxes should stack under the intro on a phone"
      assert_no_selector ".auth-figure", visible: true, wait: 0
      assert_operator rect(".auth-box")["top"], :<, 812, "the Sign in box should start on a phone's first screen"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
    assert_no_console_errors
  end
end
