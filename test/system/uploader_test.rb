require "application_system_test_case"
require "support/chunk_remote_journey"

# The chunk two-phase presigned upload, driven through a real browser.
#
# WHY THIS IS THE FIRST TEST IN THE TIER: uploader_controller.js is the upload path of the product's
# MAIN deployment (LIBRARY_BACKEND=chunk) and had no browser coverage at all. Its three server
# endpoints have six request tests between them; the browser orchestration ACROSS them — hash the
# bytes, POST begin_upload, PUT to every presigned URL, POST finalize_upload, then attach — had
# none. Nothing server-side can see that sequence, because each request in it is individually valid.
#
# THE BYTES REALLY MOVE. In test STORAGE_BACKEND defaults to `memory`, and MemoryChunkStore presigns
# to PUT /dev/blobs/*key (mounted `unless Rails.env.production?`). Those URLs are RELATIVE — which
# is exactly why the Rust integration suites use STORAGE_BACKEND=local instead — but a browser on
# the same origin follows a relative URL without complaint. So this exercises the real transport,
# not a stub.
#
# HOW TO MUTATION-CHECK THE BYTES ASSERTION, because the obvious mutation does NOT land where you'd
# expect. Dropping the finalize call (chunk_upload.js) reddens at the NODE assertion, as predicted:
# no finalize means no version, so no node. But *skipping the whole chunk-PUT loop* — leaving
# finalize in place — ALSO reddens at the node assertion, not the bytes assertion, and the reason is
# a real guard, not a test bug: FilesController#finalize_upload always calls
# Sync::Commit.finalize(verify: true), which checks every manifest chunk's existence in storage and
# raises ChunksMissing (422, caught client-side, node never created) BEFORE it will create a
# version/node. A totally-absent chunk can therefore never reach "node exists, bytes unreachable" on
# this implementation — verify:true collapses that failure mode into the same one dropping finalize
# already produces. Reproduced (both against a cleared tmp/dev-chunks*, since MemoryChunkStore blobs
# survive a transactional rollback and a stale blob from an earlier PASSING run — same reused SQLite
# user id, same content hash — silently makes a naive rerun of this mutation look green).
#
# The mutation that DOES isolate the bytes assertion is: let the PUT succeed (so verify:true's
# existence check is satisfied and the node gets created) but send the WRONG bytes, e.g. swap
# `body: bytes` for `body: new Uint8Array([1, 2, 3])`. That reddens exactly at the bytes assertion
# below, with the node assertion green — proof the assertion is load-bearing, just not reachable via
# the "skip the PUT" mutation a reader would try first.
class UploaderTest < ApplicationSystemTestCase
  setup do
    # CHUNK-SHAPED BY CONSTRUCTION, SO IT RUNS ONLY WHERE A CHUNK-FAMILY BACKEND EXISTS. The
    # two-phase presigned flow is `syncable`-gated; under a share backend /files renders the OTHER
    # branch entirely -- a multipart form with no Stimulus controller -- so this would hunt for
    # markup that is legitimately absent and fail for a reason unrelated to what it tests.
    #
    # It used to pin embedded chunk. That backend is retired (Arc D Part 2) and its replacement,
    # chunk_remote, resolves against a standalone sync server -- so the honest gate is "is one
    # configured", and this runs in `bin/ci test-chunk-remote`, which boots one. SKIPPING ON THE
    # PRECONDITION, not on the claim: §14j's recorded trap is a guard that skips on the very thing
    # it asserts, which reports success having asserted nothing.
    skip "needs a chunk-family backend (bin/ci test-chunk-remote boots one)" \
      unless ChunkRemoteJourney.configured? && LibraryBackend.name == "chunk_remote"

    @user = sign_in_as("uploader@example.com")
  end

  teardown { FileUtils.remove_entry(@attach_dir) if @attach_dir }

  test "a file chosen in the browser lands in the library through the presigned two-phase flow" do
    visit files_path

    # /files renders the plain library uploader here — the top bar's Upload since redesign slice 4
    # (app/views/layouts/_topbar_upload.html.erb's presigned-flow branch): a
    # <section data-controller="uploader"> carrying begin-url, finalize-url and the page's folder as
    # parent-node-id, which at the library root is "" (no attach-url, no redirect-url), so the file
    # lands at the library root and the controller finishes with window.location.reload() rather
    # than a redirect. Nothing below depends on that ending; the assertions poll the database.
    #
    # If this selector is missing, capabilities.port_writable? came back true and the backend pin
    # above did not take — under share/s3 this branch renders a multipart form with no Stimulus
    # controller at all.
    assert_selector "[data-controller='uploader']"

    file = Rails.root.join("test/fixtures/files/sample.txt")

    # ATTACH FROM A COPY UNDER THE OS TEMP DIR, NOT THE FIXTURE'S OWN PATH — this is a macOS-specific
    # workaround, reproduced and root-caused on this box rather than guessed at. macOS gates
    # Desktop/Documents/Downloads behind a per-app TCC consent that only a REAL Finder file-picker
    # interaction satisfies; Capybara's synthetic attach (Selenium sets the input's file list
    # directly, no picker involved) never does. Chrome still accepts the path at attach time, but the
    # async `file.arrayBuffer()` read inside chunk_upload.js then fails with a console error verified
    # verbatim on this checkout (which lives under ~/Desktop): "NotReadableError: The requested file
    # could not be read, typically due to permission problems that have occurred after a reference to
    # a file was acquired." Confirmed as path-location-specific, not a Capybara/make_visible bug: the
    # identical attach against a copy of the same bytes outside ~/Desktop succeeds every time. The OS
    # temp dir (Dir.tmpdir, e.g. /var/folders/.. or /tmp) is not one of the TCC-protected folders, so
    # copying here sidesteps it on any checkout location, not just this one. The basename is preserved
    # (sample.txt) because the node-name lookup below depends on it, and every assertion afterwards
    # still reads the ORIGINAL fixture at its real path — only where the browser is told to look
    # changes, not what is proven.
    @attach_dir = Dir.mktmpdir("uploader_test")
    attach_path = File.join(@attach_dir, file.basename.to_s)
    FileUtils.cp(file, attach_path)

    # make_visible: the real input is `hidden` behind a styled label, so Capybara cannot attach to
    # it as-is. This unhides it for the duration of the attach only, which is the narrowest change
    # that lets a real file selection happen.
    #
    # make_visible: true, NOT a CSS-selector string. Capybara's own docs describe make_visible as
    # accepting `true` (its default style overrides) or a Hash of styles to apply -- a String ends
    # up as the `css` argument to its style-patch JS, where `for (var prop in css)` walks a
    # STRING's character indices instead of a style map, silently sets nothing, and raises
    # "The style changes in :make_visible did not make the file input visible" (reproduced). No
    # locator is passed either: this branch renders exactly one `input[type=file]` on the page
    # (verified against app/views/files/index.html.erb, which has had no uploader of its own since
    # redesign slice 4, and the layout's top bar — the other upload branch is `port_writable?`-gated
    # off, and no other view fragment renders here), so Capybara's locator-less fallback
    # (descendant-or-self input[type=file]) finds it unambiguously.
    attach_file(attach_path, make_visible: true)

    # The controller writes "Done." into its status target as the last thing it does before
    # navigating, so waiting on the NODE is what proves the whole chain finished rather than that
    # the fetch was merely dispatched.
    node = nil
    assert_eventually("the uploaded file never appeared in the library") do
      node = @user.nodes.find_by(name: "sample.txt", deleted: false)
      node.present?
    end

    # THE BYTES, not just the row. A node with a version but no reachable content is exactly what a
    # half-finished two-phase flow leaves behind — begin_upload creates the pending commit, and a
    # failed PUT or a missing finalize would still leave a name in the tree on a naive
    # implementation. Reading them back through the port is what distinguishes the two.
    expected = file.binread
    assert_equal expected, FileLayer.current.read(@user, node_id: node.node_id),
                 "the node exists but its bytes did not land — the presigned PUT or finalize failed"

    assert_no_console_errors
  end

  private

    # Polls a block until it is truthy. Capybara's waiting matchers only wait on the DOM, and what
    # matters here landed in the DATABASE. Same shape as sheet_grid_test's assert_persisted_cell,
    # and for the same reason.
    def assert_eventually(message, timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
