require "application_system_test_case"

# THE LANDING IN A BROWSER (2026-10-14). Two things a request test cannot see: that `landing-main`
# actually WINS over the layout's 440px auth column (css_hygiene_test checks the selector's shape;
# only a computed width proves the cascade -- the shape the `.auth-main` specificity loss took, where
# every sign-in page rendered full width for weeks), and that the page does not scroll sideways at
# 375px (design-system.md rule 11): shell_test.rb's phone sweep is a signed-in session and never
# reaches the signed-out front door. The viewport is set through CDP for the reason that sweep
# records: headless Chrome refuses a window narrower than 500px.
class LandingSystemTest < ApplicationSystemTestCase
  test "the landing fills the page at desktop width, stands the card beside the hero, and stacks at 375px without sideways scroll" do
    visit "/"
    assert_selector ".landing-hero h1"
    assert_selector ".landing-shots img", count: 3
    assert_selector ".auth-card form input[name='user[email]']"

    main_width = page.evaluate_script("document.querySelector('main#main').getBoundingClientRect().width")
    assert_operator main_width, :>, 900,
                    "main is #{main_width}px wide: the landing is still inside the 440px auth column"
    # Beside, not below: the card's top is level with the masthead's, and the hero ends left of it.
    brand_top = page.evaluate_script("document.querySelector('.landing-brand').getBoundingClientRect().top")
    card = page.evaluate_script("(r => [r.left, r.top])(document.querySelector('.landing-auth').getBoundingClientRect())")
    hero = page.evaluate_script("(r => [r.right, r.top])(document.querySelector('.landing-hero').getBoundingClientRect())")
    assert_in_delta brand_top, card[1], 1, "the card should stand level with the masthead at desktop width"
    assert_operator hero[0], :<=, card[0], "the hero should end left of the card, not run under it"
    assert_operator hero[1], :>=, card[1] - 1, "the hero should sit beside the card, not above it"
    # The three screenshots run in one row under both.
    shot_tops = page.evaluate_script("[...document.querySelectorAll('.landing-shots li')].map(li => li.getBoundingClientRect().top)")
    assert_equal 1, shot_tops.uniq.size, "the screenshots should share one row at desktop width: #{shot_tops.inspect}"

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit "/"
      assert_selector ".landing-hero h1"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
             "the landing scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      hero_bottom = page.evaluate_script("document.querySelector('.landing-hero').getBoundingClientRect().bottom")
      card_top = page.evaluate_script("document.querySelector('.landing-auth').getBoundingClientRect().top")
      assert_operator card_top, :>=, hero_bottom, "the card should stack under the hero on a phone"
      shot_tops = page.evaluate_script("[...document.querySelectorAll('.landing-shots li')].map(li => li.getBoundingClientRect().top)")
      assert_equal 3, shot_tops.uniq.size, "the screenshots should stack on a phone: #{shot_tops.inspect}"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end
end
