require "application_system_test_case"

# The read-only CodeMirror 6 source viewer, in a real browser — the only tier that can see it.
#
# WHY THIS FILE HAS TO EXIST. Everything the Ruby suite can assert about codeview is that the page
# carries the right attributes; whether the 933 KB bundle actually loads, mounts, numbers the
# lines, highlights anything, or refuses the caret is invisible from there. CLAUDE.md §14d records
# both halves of that blind spot in this repo's own history: a Stimulus identifier resolving to
# nothing is a SILENT no-op (nine days of a dead OpenSCAD preview over a green request test), and
# an ERB comment that quotes a terminator prints its own prose into the page where no
# `assert_select` can see it. A viewer whose whole job is client-side needs a client-side guard.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, on measure_formats_test.rb's precedent and for its reason: the
# viewer must read REAL BYTES back through the port, and a tmpdir plus one scan is the cheapest
# way there. `FileLayer.reset!` in teardown is load-bearing — a direct assignment does not set
# @file_layer_backend_pinned, so test_helper's teardown will not clean up after it. This is NOT a
# backend-coverage test and must not become one.
class CodeViewerTest < ApplicationSystemTestCase
  CPP = <<~CPP.freeze
    #include <Arduino.h>

    // Blink, but slowly.
    const int LED = 13;

    void setup() {
      pinMode(LED, OUTPUT);
    }
  CPP

  GCODE = <<~GCODE.freeze
    %
    N10 G21 G90 ; millimetres, absolute
    N20 G0 X10.5 Y-3.25
    N30 M3 S12000
    (rough pass)
    N40 G1 Z-1.5 F300
  GCODE

  TXT = "just some words\nand a second line\nand a third\n".freeze

# OpenSCAD, exercising every rule the mode has: an angle-bracket include, both comment forms, a
# `$`-prefixed special variable, a keyword, a builtin and numbers.
SCAD = <<~SCAD.freeze
  include <MCAD/gears.scad>
  // A simple L bracket.
  /* two
     lines */
  $fn = 64;
  module leg(len) { cube([len, 20, 4]); }
SCAD

  # BIG ENOUGH THAT THE CAP IS OBSERVABLE ON LOOPBACK. A 300 KB file arrives in one burst before
  # any client could cancel, so it would prove nothing; 5 MB is a sliced print's order of
  # magnitude (the record (CLAUDE.md §11) records 2.1 MB for a modest .nc and notes nobody had measured a real
  # one) and leaves the difference between capped and uncapped far outside any buffering noise.
  BIG_BYTES = 5 * 1024 * 1024

  setup do
    @root = Pathname.new(Dir.mktmpdir("codeview"))
    @root.join("firmware.cpp").write(CPP)
    @root.join("pocket.gcode").write(GCODE)
    @root.join("notes.txt").write(TXT)
    @root.join("bracket.scad").write(SCAD)
    # A real g-code shape rather than filler, so the cap is exercised on the kind of file that
    # motivated it. One line is 40 bytes; the whole file is BIG_BYTES rounded to a line.
    line = "G1 X10.5 Y20.25 Z-1.5 F1200 ; cutting\n"
    @root.join("sliced.gcode").write(line * (BIG_BYTES / line.bytesize))

    FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    @user = sign_in_as("codeview@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def open_file(name)
    node_id = @user.nodes.find_by!(storage_path: name).node_id
    visit file_path(node_id)
    assert_selector ".cm-editor", wait: 10 # the bundle loaded, parsed and mounted
  end

  # READS THE TWO READ-ONLY FACTS OFF THE LIVE EditorState, not off the DOM, because the DOM can
  # only show one of them. `EditorView.editable.of(false)` is what removes the contenteditable;
  # `EditorState.readOnly.of(true)` is what refuses a document change, and nothing a browser
  # renders distinguishes it from a view that merely has no keyboard focus. Both are facets, so
  # both are readable — and asking each separately is what lets a mutation of either go red on its
  # own line instead of the pair passing because one of them held.
  #
  # The dynamic import resolves from the module cache the page already filled, so this is the SAME
  # module instance the controller used and the facet objects match by identity — which is the
  # very property config/importmap.rb's one-bundle rule exists to protect.
  def read_only_facts
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("codemirror").then((cm) => {
        const view = cm.EditorView.findFromDOM(document.querySelector(".cm-content"))
        done({ readOnly: view.state.readOnly, editable: view.state.facet(cm.EditorView.editable) })
      }).catch((e) => done({ error: String(e) }))
    JS
  end

  # The document as CodeMirror holds it, which is NOT what the DOM holds: the view renders only the
  # visible viewport, so a truncation marker 200,000 characters down never appears in any element
  # and an assert_selector for it would fail on a working page.
  def doc_facts
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("codemirror").then((cm) => {
        const view = cm.EditorView.findFromDOM(document.querySelector(".cm-content"))
        const doc = view.state.doc
        done({ length: doc.length, tail: doc.sliceString(Math.max(0, doc.length - 40)) })
      }).catch((e) => done({ error: String(e) }))
    JS
  end

  test "a source file opens in a mounted, highlighted, read-only editor" do
    open_file("firmware.cpp")

    assert_selector ".cm-lineNumbers .cm-gutterElement", minimum: 4
    assert_selector ".cm-content", text: "pinMode"
    # The fallback is REMOVED, not hidden: it is the degraded state, and leaving it behind would
    # show the file twice.
    assert_no_selector "pre.preview-text"
    # Highlighting actually ran. A language that failed to load leaves the same text with no token
    # spans at all — which is exactly the plain-text case asserted below, and the two together are
    # what make either mean anything.
    assert_selector ".cm-line span", minimum: 1

    assert_equal({ "readOnly" => true, "editable" => false }, read_only_facts)
    assert_selector ".cm-content[contenteditable=false]"

    assert_no_console_errors
  end

  # OUR OWN simpleMode, in the browser. It is a hand-written regex tokenizer for a format
  # @codemirror/legacy-modes does not carry, so nothing upstream vouches for it.
  test "the g-code mode we wrote ourselves highlights g-code" do
    open_file("pocket.gcode")

    assert_selector ".cm-content", text: "G21"
    assert_selector ".cm-line span", minimum: 3
    assert_no_console_errors
  end

  # THE DEFAULT IS NO LANGUAGE, NOT A GUESS. `txt` is deliberately absent from the table, and the
  # observable consequence is that the text is numbered and scrollable but carries no token spans.
  # Without this case the "highlighting ran" assertions above would pass just as well over a
  # viewer that highlighted everything as C++.
  test "an extension with no language renders as plain numbered text" do
    open_file("notes.txt")

    assert_selector ".cm-lineNumbers .cm-gutterElement", minimum: 3
    assert_selector ".cm-content", text: "second line"
    assert_no_selector ".cm-line span"
    assert_no_console_errors
  end

  # OUR OTHER OWN simpleMode, AND THE ONE DEFECT IN IT THAT NOTHING ELSE CAN SEE. The plan spelled
  # the `$fn` token `"variableName.special"`; @codemirror/language's stream parser resolves a
  # dotted string with the LAST part as the tag, so that spelling produces NO TOKEN TYPE AT ALL —
  # `$fn` renders completely unhighlighted — and says so only as a `console.warn`. Measured both
  # ways in this browser: `variable-2` gives a `$fn` span and an empty console; the dotted form
  # gives NO `$fn` span and `Modifier special used at start of tag`. Neither symptom is visible to
  # any Ruby test, and the warning is WARNING level, so `assert_no_console_errors` (SEVERE only)
  # would not catch it either.
  #
  # `.scad` REACHES THIS PAGE ONLY BECAUSE OF Maker::FileAttachment::TEXT_EXTS — its ROLE is
  # `cad_source`, which is not a text role. Before that constant existed the page said "No inline
  # preview for this file type" and this whole mode was documented dead code.
  #
  # TWO METHODS, NOT ONE, AND FOR template_hygiene_test.rb'S STATED REASON: minitest abandons a
  # method at its first failure, so the one defect that breaks BOTH halves — the dotted token name
  # — can only report both if they live apart. Measured: it does break both, and each message
  # points at a different thing to fix.
  #
  # THE LOG IS READ ONCE, INTO A LOCAL. `logs.get(:browser)` is a DRAIN (see
  # ApplicationSystemTestCase), so a second read in the same test — including
  # assert_no_console_errors — asserts about an already-emptied buffer, green whatever happened.
  test "the OpenSCAD mode gives a special variable its own token" do
    open_file("bracket.scad")

    assert_selector ".cm-content", text: "$fn"
    assert_selector ".cm-line span", minimum: 4
    assert_equal [ "$fn" ], page.all(".cm-line span").map(&:text).select { |t| t.start_with?("$") },
                 "the $-variable rule produced no token — check the token NAME, not the regex"
  end

  test "the OpenSCAD mode resolves every token name it uses" do
    open_file("bracket.scad")

    log = page.driver.browser.logs.get(:browser)
    assert_empty log.map(&:message).grep(/used at start of tag/),
                 "a token name in codemirror_languages.js is a dotted `tag.modifier` string; " \
                 "@codemirror/language wants a legacy CodeMirror-5 name or a bare tag, and " \
                 "drops the token entirely otherwise"
    assert_empty log.select { |l| l.level == "SEVERE" }.map(&:message)
  end

  # THE CAP IS A TRANSFER CAP NOW, NOT JUST A STRING SLICE — the fix the record's task-7 entry
  # asked for. The predecessor read `res.text()` in full and sliced afterwards, so a 20 MB sliced
  # print crossed the wire in its entirety to display 200 KB of it, and on chunk_remote those bytes
  # stream through Puma (§14a) and hold a request thread for the whole transfer.
  #
  # `transferSize` IS THE ASSERTION THAT CARRIES THE FIX. The doc length alone was already true of
  # the old controller — it truncated too, just after paying for everything. Mutation-checked by
  # deleting the `reader.cancel()` and re-running: **300 bytes with the cancel, 5,243,160 without**
  # (the file plus 280 bytes of headers). Read the 300 as a FLOOR rather than a literal wire count
  # — Chrome does not add the body of a stream the page aborted to `encodedBodySize`, so what it
  # reports for a cancelled fetch is the header overhead alone. The contrast is what the assertion
  # is about, and four orders of magnitude is not a measurement artefact.
  test "a multi-megabyte file stops transferring at the cap" do
    open_file("sliced.gcode")

    facts = doc_facts
    assert_equal 200_000 + "\n… (truncated)".length, facts["length"],
                 "the document is the cap plus the marker, not the whole file"
    assert_match(/… \(truncated\)\z/, facts["tail"])

    transferred = page.evaluate_script(<<~JS)
      (performance.getEntriesByType("resource")
        .filter((e) => e.name.includes("/blob"))
        .map((e) => e.transferSize)[0]) || null
    JS
    assert_operator transferred, :<, 1_000_000,
                    "#{transferred} bytes crossed the wire for a #{BIG_BYTES}-byte file — the " \
                    "stream cancel in codeview_controller#fetchHead is not stopping the transfer"
    assert_no_console_errors
  end
end
