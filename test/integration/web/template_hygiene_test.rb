require "test_helper"

module Web
  # A RENDERED PAGE MUST NEVER CONTAIN ERB DELIMITERS.
  #
  # THIS EXISTS BECAUSE IT HAPPENED, and because nothing else in the suite could see it. An ERB
  # comment ends at its FIRST `%>`, so a comment that quotes a snippet containing one terminates
  # early and prints its own remaining prose into the document. The page still parses, every
  # `assert_select` in the suite still passes — they ask about ELEMENTS, and this defect produces a
  # TEXT NODE — and the only symptom is three lines of a code comment sitting in the middle of the
  # user's Files page. Caught by opening the page in a browser, which is the argument for probing
  # over reasoning in one screenshot.
  #
  # A STATIC SCAN OF THE TEMPLATES WAS TRIED FIRST AND IS THE WEAKER GUARD: it has to guess whether
  # the text after a comment's terminator was meant to be markup or prose. Asserting on the RENDERED
  # OUTPUT needs no such guess — a delimiter in the response is wrong however it got there, which
  # also covers escaping mistakes and half-written tags this rule was not aimed at.
  #
  # BACKEND-NEUTRAL BY CONSTRUCTION: it drives pages, and every page here renders on all three.
  class TemplateHygieneTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "hygiene-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "d-laser", name: "laser", kind: "dir")
      @user.nodes.create!(node_id: "n-stl", name: "bracket.stl", kind: "file", mtime: 1, size: 5)
      @user.nodes.create!(node_id: "n-bak", name: "sign_backup.lbrn2", kind: "file",
                          parent_node_id: "d-laser", mtime: 1, size: 5)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @project.file_attachments.create!(user: @user, node_id: "n-stl", role: "model", position: 0)
      @project.file_attachments.create!(user: @user, node_id: "n-bak", role: "laser", position: 1)
      @project.file_attachments.create!(user: @user, node_id: "gone", role: "model",
                                        label: "ghost.stl", position: 2)
      @project.tasks.create!(user: @user, title: "Cut the base", status: "todo", position: 0)
    end

    # Every page touched by this branch, plus the ones whose partials it shares. The filtered and
    # grid variants are listed separately because they render DIFFERENT partials — the leak that
    # prompted this was in `files/_ext_filter`, which the grid renders and the file page does not.
    def pages
      {
        "files (list)" => files_path(view: "list"),
        "files (grid)" => files_path(view: "grid"),
        "files (filtered)" => files_path(ext: "stl"),
        "files (in a folder)" => files_path(folder: "d-laser"),
        "file detail" => file_path("n-stl"),
        "projects index" => projects_path,
        "project detail" => project_path(@project),
        "project new" => new_project_path,
        "project edit" => edit_project_path(@project),
        "models index" => models_path,
        "trash" => trash_index_path
      }
    end

    test "no page renders an ERB delimiter into its output" do
      pages.each do |name, path|
        get path
        assert_response :success, "#{name} (#{path}) did not render"
        # `<%` and `%>` BOTH, because a comment that terminates early leaks the CLOSER of the
        # snippet it quoted, not an opener — checking only for `<%` would have missed this exact bug.
        assert_not_includes response.body, "<%", "#{name} leaked an ERB opener into the page"
        assert_not_includes response.body, "%>", "#{name} leaked an ERB closer into the page"
      end
    end

    # THE OTHER HALF OF THE SAME FAILURE, and the one a delimiter check alone would miss: a comment
    # can leak prose that happens to contain no delimiter at all. These are phrases that only ever
    # appear in the code comments of the templates this branch touched, so finding one in a response
    # means a comment is being rendered.
    LEAKED_PROSE = [ "BOOLEAN attribute", "NOT AN OVERSIGHT", "mutation-check", "§14", "§15" ].freeze

    test "no page renders the prose of its own code comments" do
      pages.each do |name, path|
        get path
        LEAKED_PROSE.each do |phrase|
          assert_not_includes response.body, phrase,
                              "#{name} rendered a code comment into the page (found #{phrase.inspect})"
        end
      end
    end
  end
end
