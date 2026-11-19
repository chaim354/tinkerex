require "test_helper"

# NO LINK TO A GIT PAGE IS PREFETCHED. Turbo 8 prefetches a link on hover, and the commit page and the
# history page are the two pages here whose GET runs git: `RepoCommitsController#load_repo` asks
# `LocalRepo#committable?`, which walks the working tree's status, and the history page walks
# commits. On a NAS that is real disk work paid for every pointer that crosses the link, and the
# project page's half-width panels (Shop manual slice 5) put a repository's Commits and History links
# under the path a panel drag takes: `page_editor_test.rb`'s drag hovered one long enough to prefetch
# a fixture repository's commit page, and the test died on that request's error, intermittently.
#
# A static scan rather than a rendered one, because the links live in seven partials across three
# pages and a repository's card only renders on a share deployment with a working tree; the scan
# reads every `link_to` call that names either path, up to the `%>` that ends it, so a call split
# over two lines is read whole.
#
# MUTATION-CHECKED (§15): dropping `data: { turbo_prefetch: false }` from projects/_repo_card's
# History link reddens this, naming that file.
class GitLinkPrefetchTest < ActiveSupport::TestCase
  GIT_PATHS = /\b(?:repo_commit_path|repo_history_path)\b/

  test "every link to the commit or history page opts out of Turbo's prefetch" do
    calls = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |path|
      File.read(path).scan(/<%=\s*link_to\b.*?%>/m).select { |call| call.match?(GIT_PATHS) }
                     .map { |call| [ path.delete_prefix("#{Rails.root}/"), call ] }
    end
    assert_operator calls.size, :>=, 10, "found only #{calls.size} links to a git page; the scan is vacuous"

    offenders = calls.reject { |_, call| call.include?("turbo_prefetch: false") }
    assert_empty offenders.map(&:first),
                 "these links to a git page are prefetched on hover, which runs git for a pointer passing by"
  end
end
