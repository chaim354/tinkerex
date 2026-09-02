#!/usr/bin/env bash
# Which self-hosted runner families are available for this run?
#
# WHY THIS IS A DECLARATION AND NOT AN API CALL — do not "fix" this into `gh api`:
# listing self-hosted runners requires the `administration` permission, which is NOT among the
# permissions a workflow GITHUB_TOKEN can be granted. `gh api repos/:owner/:repo/actions/runners`
# 403s from inside Actions. It works from a developer shell only because a personal token carries
# admin scope — and ci/runners/README.md documents it that way, which is the trap. So the fleet is
# DECLARED in the repo variable CI_RUNNERS and read here.
#
# Usage:
#   ci/preflight.sh              # `family=true|false` lines, one per family, for $GITHUB_OUTPUT
#   ci/preflight.sh --summary    # a markdown report, for $GITHUB_STEP_SUMMARY
#
# THE DEFAULT IS DELIBERATELY CONSERVATIVE: ONE FAMILY, NEVER ALL THREE. An unset or blank
# CI_RUNNERS means "linux only" — linux because that is where this repo's runners live since CI
# moved to the Unraid box (2026-08-31). A default of everything-available reproduces the exact bug
# this script exists to prevent: jobs scheduled against runners that do not exist, queueing for 24h
# before GitHub cancels them, at 0 elapsed, with no red signal anywhere. Five weeks of dark CI came
# from that.
#
# The summary deliberately does NOT enumerate the skipped JOBS. GitHub already lists them by name in
# the run, and a hand-maintained job list here would be a fourth thing to drift. What the summary
# owes the reader is the REASON and the declared value — so a stale declaration is visible at the
# point where it does damage.
set -euo pipefail

FAMILIES="macos linux windows"
DEFAULT="linux"

declared="${CI_RUNNERS:-}"
if [ -z "${declared//[[:space:]]/}" ]; then
  declared="$DEFAULT"
fi

# Lowercase, strip all whitespace, and wrap in commas on BOTH ends so a lookup matches a whole
# family name. Without the wrapping, a declared "linux-arm64" would satisfy a "linux" lookup and
# schedule x86 FUSE jobs onto an arm box.
normalised=",$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'),"

available() {
  case "$normalised" in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

# DOES ANY WORKFLOW IN THIS REPO ACTUALLY SCHEDULE A JOB ON THIS FAMILY?
#
# DERIVED, NOT DECLARED. The header above refuses to hand-maintain a job list because it would be
# a fourth thing to drift; the same objection applies to hand-maintaining "which families this
# repo uses". A grep over the workflow dir cannot go stale.
#
# Deliberately crude: it matches the family name anywhere in a `runs-on` line, which over-reports
# rather than under-reports. Over-reporting restores the OLD wording (a warning about skipped
# coverage) and is safe; under-reporting would hide a real gap, which is the failure this whole
# script exists to prevent.
#
# `[[:space:]]`, not `\s`: the runner is macOS and BSD grep -E does not honour `\s`.
#
# WHERE THE WORKFLOWS ARE, resolved from THIS SCRIPT's location rather than $PWD: the workflow
# invokes it from the repo root, but a test or a developer need not. CI_WORKFLOW_DIR overrides it,
# and that override is not a testing convenience -- it is what lets test/ci_preflight_test.rb
# ESTABLISH the precondition the "absent -- its jobs were SKIPPED" branch reports on. This repo has
# no linux/windows job left, so without an override that branch is unreachable from a test, and a
# guard whose precondition is never established cannot fail for the reason it exists (CLAUDE.md
# §15). Pointing a probe at the REAL .github/workflows/ instead would break ci_hygiene_test (an
# ungated linux job) and collide between parallel test workers.
WORKFLOW_DIR="${CI_WORKFLOW_DIR:-"$(cd "$(dirname "$0")/.." && pwd)/.github/workflows"}"

targeted() {
  grep -rhE '^[[:space:]]*runs-on:' "$WORKFLOW_DIR" 2>/dev/null | grep -q "$1"
}

if [ "${1:-}" = "--summary" ]; then
  absent=""
  for family in $FAMILIES; do
    targeted "$family" && ! available "$family" && absent="$absent \`$family\`"
  done

  echo "## CI runner preflight"
  echo
  echo "Declared fleet (repo variable \`CI_RUNNERS\`): \`$declared\`"
  echo
  echo "| Runner family | Status |"
  echo "|---|---|"
  for family in $FAMILIES; do
    if ! targeted "$family"; then
      echo "| \`$family\` | — no job in this repo targets it |"
    elif available "$family"; then
      echo "| \`$family\` | ✅ available |"
    else
      echo "| \`$family\` | ⛔ **absent — its jobs were SKIPPED** |"
    fi
  done
  echo

  if [ -n "$absent" ]; then
    echo "> **This coverage was skipped, not passed.** Jobs requiring$absent were never scheduled,"
    echo "> so a green run here is green about less than a full run would be. The skipped jobs are"
    echo "> listed by name in this run's job list."
    echo ">"
    echo "> Register the runner (\`ci/runners/README.md\`) and add the family to the \`CI_RUNNERS\`"
    echo "> repo variable, or accept the gap knowingly."
  else
    echo "> No coverage skipped: every family this repo schedules jobs on is declared available."
    echo ">"
    echo "> A \`—\` row is NOT a passing row. It means this repo has no job for that family at all"
    echo "> — the sync↔client suites that did left on 2026-08-25"
    echo "> (\`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md\`). That coverage now lives"
    echo "> in \`tinkerex-sync\` and \`tinkerex-client\`, and this run says nothing about it."
  fi
  exit 0
fi

for family in $FAMILIES; do
  if available "$family"; then
    echo "$family=true"
  else
    echo "$family=false"
  fi
done
