require "test_helper"
require_relative "support/worker_budget"
require_relative "system/support/web_helpers"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # CAPYBARA'S 2-SECOND DEFAULT IS TOO TIGHT FOR THIS APP'S ADDON PAGES, AND IT COST US A RECURRING
  # CI FLAKE.
  #
  # MEASURED, not guessed. An addon page's content does not arrive with the HTML: the shell renders
  # a Stimulus controller, the bundle is fetched through the same-origin asset proxy, its ESM
  # top-level runs, it calls a sidecar for its generator list, and only then does it build the
  # `<details id="box-section-*">` elements the tests assert on. Timed on an unloaded box: **0.114 s
  # on the first visit in a process, ~0.06 s warm**. So the page is not slow — 2 s is simply a
  # budget with no headroom for a chain that has five async steps in it.
  #
  # WHAT IT ACTUALLY BROKE: `BoxSectionsTest` failed on two consecutive PRs (#235, #237) with
  # `expected to find css "#box-section-tray" but there were no matches`, on a DIFFERENT test each
  # time, ~3 seconds into the run, passing on re-run every time and never once reproducing in
  # isolation locally (6 consecutive clean runs). That profile is contention, not a broken selector.
  #
  # THE CONTENTION IS THIS REPO'S ORDINARY CONFIGURATION, which is why raising the budget is the
  # right response rather than a shrug: the CI runner IS a developer's own Mac (§15 — the mac
  # runner is registered on this machine), so a local `bin/ci` and a CI job share one box. The
  # worker budget beside this already exists for exactly that condition, and its own comment says
  # memory pressure makes "every Capybara wait a coin flip". Reproduced deliberately here by
  # running two browser suites at once: **152 and 166 errors** across the pair, against 0 when
  # either runs alone.
  #
  # RAISING THIS IS FREE ON A GREEN RUN. A Capybara wait returns the instant its element appears,
  # so a passing suite is not slowed by one millisecond — the only thing that grows is how long a
  # GENUINELY missing element takes to report. 10 s absorbs a ~100x slowdown from the measured
  # 0.1 s baseline while still failing fast enough to read.
  #
  # DO NOT reach for this to fix a test that fails consistently: that is a real defect, and a
  # longer wait only makes it slower to find out.
  Capybara.default_max_wait_time = 10

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
