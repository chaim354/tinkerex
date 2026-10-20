require "test_helper"

# bin/log IS THE SINGLE WRITE DOOR ONTO THE RECORD (CLAUDE.md §11, §13). This file turns that
# sentence from a claim into a check: no other tracked file may address Kaneo's task, label or
# comment endpoints, which are where every record write lands.
#
# BOTH SPELLINGS A CLIENT USES ARE MATCHED, AND THE SECOND ONE IS THE REASON THIS IS NOT A LITERAL.
# bin/log writes the prefix out (`"/api/task/#{id}"`), and so would a curl recipe. bin/migrate-record
# — a second committed client, with DELETE verbs, retired 2026-10-19 — hoisted `/api` into its
# `kaneo()` helper, so every call site opened its string on the resource (`kaneo(:post,
# "/task/#{pid}", ...)`) and never contained `/api/task` at all. Measured before this was written:
# a guard matching only the `/api/...` literals stays GREEN with that file restored.
#
# THREE EXEMPTIONS, EACH ARGUED. bin/log is the door. test/ is the door's own tests, which stub these
# endpoints. Markdown under docs/ is prose and history — the plans, specs and audits that describe
# the wire; a document naming an endpoint does not call it. Markdown ANYWHERE ELSE stays in scope on
# purpose: a .claude/commands/*.md is instructions an agent carries out, and a curl recipe there is a
# second write door in everything but its file type.
class RecordDoorHygieneTest < ActiveSupport::TestCase
  DOOR = "bin/log".freeze

  # A path naming one of the three resources, opened either by the `/api` prefix or by the quote that
  # starts a path literal. `\b` keeps `/tasks`, `/labels` and `/comments` — no Kaneo path — out.
  KANEO_WRITE_RESOURCE = %r{(?:/api|["'`])/(?:task|label|comment)\b}

  def exempt?(path)
    path == DOOR || path.start_with?("test/") || (path.start_with?("docs/") && path.end_with?(".md"))
  end

  test "no tracked file but bin/log addresses Kaneo's task, label or comment endpoints" do
    tracked = IO.popen([ "git", "ls-files", "-z" ], chdir: Rails.root.to_s, &:read).split("\0")

    # NON-VACUOUS FIRST (§14e): a scan that lists nothing, or a pattern that matches nothing, passes
    # `assert_empty` perfectly. So the door must be in the scanned set, and the pattern must find all
    # three resources IN THE DOOR — narrowing it to one resource, or breaking it, goes red here.
    assert_includes tracked, DOOR, "git ls-files did not list #{DOOR} — the scan below would pass over nothing"
    found = Rails.root.join(DOOR).read.scan(KANEO_WRITE_RESOURCE).map { |hit| hit[/task|label|comment/] }
    assert_equal %w[comment label task], found.uniq.sort,
                 "the pattern no longer recognises every write resource in #{DOOR} itself, so it " \
                 "cannot be trusted to recognise them anywhere else"

    # THE EXEMPTIONS ARE PINNED TOO, ONE ASSERTION PER ARM. An `exempt?` answering true for
    # everything passes the scan over any file at all — measured in review: with that mutation and
    # bin/migrate-record restored, this test stayed green.
    refute exempt?("bin/migrate-record"), "a second client must never be exempt"
    refute exempt?(".claude/commands/finish-branch.md"), "Markdown outside docs/ is instructions, in scope"
    refute exempt?("docs/superpowers/specs/2026-08-27-git-tracked-projects-spike.sh"),
           "a script under docs/ can call the wire; only its Markdown is exempt"
    assert exempt?("docs/superpowers/plans/2026-08-31-forgejo-to-kaneo.md"), "docs/ Markdown is history"
    assert exempt?("test/log_cli_test.rb"), "the door's own tests stub these endpoints"

    offenders = tracked.reject { |path| exempt?(path) }.select do |path|
      file = Rails.root.join(path)
      file.file? && file.binread.match?(KANEO_WRITE_RESOURCE)
    end

    assert_empty offenders,
                 "#{offenders.join(', ')} addresses Kaneo's record endpoints. #{DOOR} is the SINGLE " \
                 "write door onto the record (CLAUDE.md §11, §13): add a subcommand there instead of " \
                 "a second client, because a second door drifts from the first in silence"
  end
end
