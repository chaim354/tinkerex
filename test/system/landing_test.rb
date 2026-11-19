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
end
