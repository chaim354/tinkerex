require "test_helper"
require_relative "support/worker_budget"
require_relative "system/support/web_helpers"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # BROWSER WORKERS ARE BUDGETED BY MEMORY, NOT BY CORE COUNT — the argument, the measurements and
  # the three probes that ruled out CPU load are all in `test/support/worker_budget.rb`. Short
  # version: a system-test worker carries a whole Chrome, ten of them take 19.7 GB of this 24 GB
  # box and leave 0.1 GB free, and the resulting swap makes every Capybara wait a coin flip.
  #
  # THIS OVERRIDES `test_helper.rb`'s `parallelize` ON PURPOSE, and only for system runs.
  # `parallelize` assigns the global `Minitest.parallel_executor`, so the last call wins — and this
  # file is loaded ONLY when system tests are (`bin/rails test` does not load it), so the unit
  # suite keeps the processor-count default it should have. Unit workers are cheap; browser workers
  # are not, and that difference is the whole reason the two now differ.
  #
  # `PARALLEL_WORKERS` STILL WINS over this, because `parallelize` checks the environment before it
  # looks at the `workers:` argument. The escape hatch `test_helper.rb` documents is unaffected.
  #
  # DO NOT move this call into `test_helper.rb` behind a "are we running system tests?" test. There
  # is no reliable one — the runner does not announce itself — and the load-order property above is
  # both simpler and enforced by the file layout rather than by a guess.
  parallelize(workers: WorkerBudget.browser_workers)

  include WebHelpers

  # THE BROWSER LOG BUFFER OUTLIVES A TEST. Selenium reuses one Chrome across the whole file, and
  # `logs.get(:browser)` is a DRAIN — so a test that never calls `assert_no_console_errors` (or one
  # that fails before reaching it) hands its entries to whichever test runs next, which then fails
  # for a completely different test's reason. Observed for real: box_sections_test's deliberate
  # sample-photo 404s failed importer_test.
  #
  # Draining here also makes the guard SHARPER, not weaker: each test now asserts about its own
  # page only, instead of inheriting a backlog it can't explain.
  setup do
    page.driver.browser.logs.get(:browser) if page.driver.respond_to?(:browser)
  end
end
