require "application_system_test_case"
require "support/public_fixture"

# THE CHOSEN TAG ON THE EXPLORE PAGE IS DRAWN IN INK (design-system.md rule 13: selection is ink).
# Its chips are links, so the chosen one says `aria-current`, and the fill is drawn from that by
# the one rule in components.css. It used to be the public sheet's own copy of the three
# declarations, keyed on a class. Only a browser can see a fill: the markup carried the class and
# the attribute either way.
class ExploreChipTest < ApplicationSystemTestCase
  include PublicFixture

  setup do
    @root = use_fresh_share_library!
    @user = make_owner!(handle: "ada") # PublicFixture's own helpers read @user
    seed_public_project!(@user, tags: "lamp, laser")
  end

  test "the chosen tag chip is drawn selected, and the others are not" do
    visit public_explore_path(tag: "lamp")

    chosen = ".explore-chips a.tag-chip[aria-current='page']"
    assert_selector chosen, text: /\Alamp/
    assert_equal ink_colour, background_of(chosen)
    assert_not_equal ink_colour, background_of(".explore-chips a.tag-chip:not([aria-current])")
    # UNDER THE POINTER TOO: `.tag-chip:hover` has the same specificity as the selected rule and
    # sets the text to ink, which on an ink fill is no text at all. The selected rule comes later.
    find(chosen).hover
    assert_equal ink_colour, background_of(chosen)
    assert_not_equal ink_colour, page.evaluate_script("getComputedStyle(document.querySelector(#{chosen.to_json})).color")
  end

  # A PROJECT ROW KEEPS ITS TEXT COLUMN ON A PHONE (Shop manual slice 8; pages/public.css). The list is
  # a grid of number, cover, text and side, and below 480px the cover leaves so the name and its
  # sentence take the row. A row that kept its cover there put the text in the 22px number track, one
  # letter a line, with nothing scrolling sideways, so shell_test.rb's 375px overflow sweep read it
  # green; a screenshot found it. Read as a measured width.
  # Mutation-checked (2026-11-19): `.card-cover { display: block }` moved back below the phone rules
  # reddened this as "the name has 22px of a 375px row".
  test "on a phone a project row gives its name the row, not the number's track" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit public_explore_path
    assert_selector ".project-card-grid .project-card h2.card-title", text: "Desk Lamp"
    width = page.evaluate_script("document.querySelector('.project-card-grid .card-title').getBoundingClientRect().width").round
    assert_operator width, :>=, 250, "the name has #{width}px of a 375px row"
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
