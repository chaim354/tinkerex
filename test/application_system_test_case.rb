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
  # THE CONTENTION WAS THIS REPO'S ORDINARY CONFIGURATION WHEN THIS WAS WRITTEN, and the headroom is
  # still right now that it is not. Until 2026-08-31 the CI runner WAS a developer's own Mac, so a
  # local `bin/ci` and a CI job shared one box; reproduced deliberately by running two browser
  # suites at once: **152 and 166 errors** across the pair, against 0 when either runs alone. CI now
  # runs on dedicated Unraid containers (ops/ci-runner-stack.yml), which removes that particular
  # collision — but four runners share one 36-core host, and the worker budget beside this is what
  # keeps them from each planning for an empty box. The 2 s default still has no headroom for a
  # five-step async chain, which is the reason that survives the move.
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
  # ANNOUNCE THIS SUITE BEFORE ASKING FOR THE BUDGET, AND THE ORDER IS THE WHOLE POINT.
  #
  # `browser_workers` now asks whether ANOTHER browser suite is live rather than inferring it from
  # free memory (see worker_budget.rb for why the memory proxy was permanently tripped on this
  # box). Two suites started at the same instant could otherwise both check before either had
  # registered, and both plan for an empty machine — exactly the 152/166-error condition the
  # budget exists to prevent. Writing our pidfile first closes that window: the loser of the race
  # sees the winner. Our own pid is excluded from the check, so this never throttles us.
  WorkerBudget.register!

  parallelize(workers: WorkerBudget.browser_workers)

  include WebHelpers

  # A ROLLED-BACK DATABASE ID MAKES THE BROWSER'S HTTP CACHE LIE, SO EVERY TEST STARTS WITH IT
  # EMPTY.
  #
  # System tests roll back transactionally, so autoincrement ids RESTART FROM 1 in each test --
  # ActiveStorage blob ids among them. A URL that DERIVES from such an id is therefore not unique
  # across a run: a later test mints the BYTE-IDENTICAL URL for completely different content, and
  # Chrome -- which reuses one profile for every test in a worker -- answers it out of cache with
  # the earlier test's body. Nothing on the server is wrong, nothing raises, no request is even
  # made: the page simply draws another test's data.
  #
  # WHAT IT ACTUALLY BROKE. The Measure view fetches its payload from the blob URL
  # `FilesController#geometry` names -- `/rails/active_storage/blobs/redirect/<signed_id>/<name>`,
  # whose `signed_id` is a signed `blob.id` -- and ActiveStorage's redirect controller marks that
  # 302 cacheable for `ActiveStorage.service_urls_expire_in`. `LbrnMeasureTest` intermittently drew
  # `plate.svg`, an 80 x 40 rect belonging to `measure_formats_test.rb`, A DIFFERENT FILE ENTIRELY:
  # 1-3 failures per run on a DIFFERENT test each time, and once as a `.measure-dims` reading
  # "80 x 40 mm" against a 60 x 40 fixture. Instrumented and confirmed, not inferred -- the node,
  # its storage_path, its user and `FileLayer.current.root` were all the test's own, and the SERVER
  # returned another file's payload. Adding `measure_export_test.rb` (200 -> 215 runs) shifted the
  # blob-id sequence enough to line the collisions up; the branch point is green on the same seed.
  #
  # CLEARED HERE RATHER THAN FIXED AT THE ENDPOINT, and that scope is the point. The hazard is not
  # geometry's: it is EVERY response a browser may cache whose URL is keyed on an id the rollback
  # rewinds. Making one controller's responses no-store leaves the next one to rediscover this from
  # scratch, and `cache: "no-store"` in `measure_controller.js` would launder a test-isolation
  # defect into production code -- where ids never restart, a repointed preview row gets a NEW blob
  # and so a new URL, and caching the payload is correct.
  #
  # FREE ON A GREEN RUN: one CDP round trip per test, no browser restart, no navigation.
  #
  # GUARDED, NOT ASSUMED. `execute_cdp` is a Chromium driver extension, so a rack_test or
  # non-Chromium driver DEGRADES to doing nothing rather than raising -- the same shape as the log
  # drain below. Mutation-checked: commenting this block out brings the flakiness straight back.
  setup do
    browser = page.driver.browser if page.driver.respond_to?(:browser)
    browser.execute_cdp("Network.clearBrowserCache") if browser.respond_to?(:execute_cdp)
  end

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
