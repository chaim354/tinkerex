# What has happened in one repository the maker brought — the repository-wide half of the question
# the file page's history panel asks about a single path (tinkerex#178).
#
# SESSION-AUTHED, NEVER THE v1 API (§14d): /v1/* is device-token; the web app is cookies.
#
# ONE CAPPED WALK, THE SAME ONE. `Maker::Git::History` answers both questions, so this page and the
# panel cannot drift on ordering, on where the walk stops, or on what stopping early means. There
# is no "all history" call and there must never be one: measured on the live share deployment
# against a 333-commit repository over its real CIFS mount, a full walk is 4,917 ms against 104 ms
# capped (spec part 3).
#
# READ-ONLY. Nothing here writes, and restore is deliberately NOT offered from this page: a restore
# is per-file, and it belongs beside the file it changes, where the maker can see what they are
# replacing.
class RepoHistoriesController < ApplicationController
  before_action :load_repo

  def show
    @result = Maker::Git::History.new(@local).for_repo
  end

  private

  # RepoCommitsController#load_repo, VERBATIM IN SHAPE AND DELIBERATELY SO. Two pages over one
  # repository must not disagree about whether it can be opened, and `LocalRepo#refusal` is the one
  # method that answers -- it asks `local_worktree?` FIRST and returns before touching `workdir`,
  # which is what keeps this off `FileLayer::Share#absolute_path`, the only adapter that has one.
  #
  # IT REFUSES MORE THAN READING HISTORY STRICTLY NEEDS -- a lock file or a half-finished rebase
  # does not make `git log` wrong -- and that is the trade taken on purpose. A second, looser
  # refusal here would be a second answer to one question (§14a), and the first thing a maker does
  # from a history page is restore something.
  def load_repo
    @root = current_user.nodes.present.find_by!(node_id: params[:root_id], kind: "dir")
    @local = Maker::Git::LocalRepo.open(current_user, @root)
    return if @local.committable?

    redirect_to files_path, alert: @local.refusal
  end
end
