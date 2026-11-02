require "test_helper"
require "support/git_repo_fixture"

module Web
  # THE COMMIT BOX NAMES ITS CONTROLS (UX audit D6 and I, 2026-11-02): the message had a placeholder
  # and no label, and each path's checkbox had no `<label for>`, so a screen reader announced a row
  # of unnamed boxes and a click on a path did nothing. The ids are a digest of the path, because
  # `parameterize` folds "a.txt" and "a-txt" into one id — harmless while nothing pointed at it, and
  # a label ticking the wrong box once one does.
  class RepoCommitLabelsTest < ActionDispatch::IntegrationTest
    include GitRepoFixture

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @library = use_fresh_share_library!
      @user = User.create!(email: "rcl-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "the message has a label and every path's checkbox is labelled by its path" do
      root = make_repo!(name: "demo", files: { "a.txt" => "1\n", "a-txt" => "2\n" })
      dir = File.join(library_root, "demo")
      File.write(File.join(dir, "a.txt"), "one\n")   # two changes outside tinkerex, whose names
      File.write(File.join(dir, "a-txt"), "two\n")   # parameterize to the same id

      get repo_commit_path(root.node_id)
      assert_response :success
      assert_select "label[for=message]", text: "Commit message"
      assert_select "textarea#message[name=message]"

      boxes = css_select("input[name='paths[]']")
      assert_operator boxes.size, :>=, 2, "the fixture offered fewer than two paths, so the ids prove nothing"
      assert_equal boxes.size, boxes.map { |box| box["id"] }.uniq.size, "two paths' checkboxes share an id"
      boxes.each do |box|
        label = css_select("label[for='#{box["id"]}']")
        assert_equal 1, label.size, "#{box["value"]}'s checkbox has no label"
        assert_equal box["value"], label.first.text.strip
      end
    end
  end
end
