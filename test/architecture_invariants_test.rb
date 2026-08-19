require "test_helper"

# Executes the two "standing tripwire greps" that CLAUDE.md cites as PROOFS of the maker/file-layer
# boundary (§14a, §14c) and of the capability-gate design (§14a).
#
# WHY THIS FILE EXISTS. Until now both were prose. Nothing ran them, and one had already drifted
# undetected: it read "returns nothing" for months after the addon framework made the true answer
# "exactly one hit, and it is library_output.rb" — corrected only when a fresh reader happened to
# type the command. A proof nobody runs is a comment. Same pattern as ci_hygiene_test.rb and
# deploy_hygiene_test.rb: guard the facts no other test can see.
#
# Implemented by READING FILES, not by shelling out to grep — the same choice deploy_hygiene_test.rb
# makes when it parses YAML instead of grepping it. No shell, no BSD/GNU differences, and the
# comment-stripping becomes explicit instead of riding on a fragile `grep -v ':[0-9]*: *#'`.
class ArchitectureInvariantsTest < ActiveSupport::TestCase
  ROOT = Rails.root

  # Lines of real code (not comments) matching `pattern`, as "path:lineno" strings.
  #
  # Skipping comment lines is LOAD-BEARING, not tidiness. Both greps below have comments in-tree
  # that *describe* the coupling they forbid, so the un-filtered form has never returned what the
  # docs claim — which is precisely how the drift went unnoticed. This only strips whole-line
  # comments, matching `grep -v ':[0-9]*: *#'`; a trailing comment on a code line still counts, and
  # should, because the code on it is real.
  def offending(globs, pattern)
    Array(globs).flat_map { |rel| Dir.glob(ROOT.join(rel, "**", "*.rb")) }.sort.flat_map do |file|
      File.readlines(file, chomp: true).each_with_index.filter_map do |line, idx|
        next if line.lstrip.start_with?("#")
        next unless line.match?(pattern)
        "#{Pathname.new(file).relative_path_from(ROOT)}:#{idx + 1}"
      end
    end
  end

  test "the maker layer reaches for chunk internals in exactly one place, and that place is the addon output path" do
    # CLAUDE.md §14c. The maker layer must not know files are chunks — that is the whole point of
    # the FileLayer port. The ONE legitimate exception is addon-generated output, which has no
    # client to presign for: in chunk mode the server itself drives a single-chunk Sync::Commit plus
    # the put, mirroring what the web uploader does from the browser.
    #
    # The assertion is "one hit, and it is library_output.rb" — NOT "no hits". Asserting zero would
    # be asserting something false, and asserting only the count would let the coupling migrate to
    # some other file while the test stayed green.
    # The directory set is DERIVED FROM THE TREE — `app/**/maker` is every maker directory there
    # is — so a NEW `app/<x>/maker/` is covered the day it is created. It was a remembered list
    # of three and silently missed `app/controllers/v1/maker` + `app/models/concerns/maker` (15
    # files), where a ChunkStore call left this test GREEN over a live §14a breach — in the very
    # file §14a introduced to replace a remembered grep. Derive, don't enumerate: the same rule as
    # stimulus_hygiene_test.rb's registered_identifiers.
    hits = offending(%w[app/**/maker], /manifest_chunks|ChunkStore/)

    assert_equal 1, hits.size,
                 "expected exactly ONE chunk-internals reference in the maker layer, got #{hits.size}:\n" \
                 "  #{hits.join("\n  ")}\n" \
                 "A NEW one means the maker/file-layer split (CLAUDE.md §14a) has been breached — " \
                 "route the write through FileLayer#write or Sync::Commit instead. If the existing " \
                 "one MOVED, update this test and CLAUDE.md §14c together."
    assert_match %r{\Aapp/services/maker/addons/library_output\.rb:\d+\z}, hits.sole,
                 "the one permitted chunk-internals reference must live in " \
                 "Maker::Addons::LibraryOutput (the single addon output path), but it is at #{hits.sole}"
  end

  test "NotImplementedError is never rescued" do
    # CLAUDE.md §14a. The 501 for an unsupported backend op is a capability gate BEFORE the call,
    # never a rescue. Three reasons, all recorded at app/controllers/concerns/library_capabilities.rb:
    #
    #   1. NotImplementedError is a ScriptError, NOT a StandardError. A bare `rescue => e` and
    #      ActiveJob's `retry_on` therefore do not catch it at all. A rescue-based gate does not
    #      have a gap — it does not work, and fails to exactly the 500 the design forbids.
    #   2. A 501 from Chunk#write would be factually wrong: it means the CALLER used the wrong door,
    #      not that the deployment cannot accept uploads.
    #   3. A controller rescue catches it from anywhere below, laundering a real s3 MISCONFIGURATION
    #      at FileLayer.build into a routine-looking response.
    #
    # So it stays un-rescued and loud, and the capability gates are what keep it unreachable.
    hits = offending(%w[app lib], /rescue.*NotImplementedError/)

    assert_empty hits,
                 "NotImplementedError must never be rescued (CLAUDE.md §14a), found:\n" \
                 "  #{hits.join("\n  ")}\n" \
                 "It is a ScriptError, so this rescue does not do what it looks like it does. " \
                 "Gate on the capability before the call instead — see LibraryCapabilities."
  end
end
