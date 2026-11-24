require "test_helper"

module Maker
  # WHETHER A PROJECT STACKS VERSIONS (2026-11-24): the project's own choice when it made one, the
  # owner's master default (Settings) when it did not. One method, so no panel reads a column.
  class ProjectStackingTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "stk-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                           omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "a new account stacks, and a project with no choice of its own follows it" do
      assert @user.stack_versions, "on is the shipped default for every account"
      assert_nil @project.stack_versions
      assert @project.stacking?

      @user.update!(stack_versions: false)
      refute @project.reload.stacking?, "the master default decides while the project has no choice"
    end

    test "a project's own choice wins over the default either way" do
      @user.update!(stack_versions: false)
      @project.update!(stack_versions: true)
      assert @project.stacking?

      @user.update!(stack_versions: true)
      @project.update!(stack_versions: false)
      refute @project.reload.stacking?
    end

    test "the layout is handed the answer" do
      @project.update!(stack_versions: false)
      refute @project.panel_layout.stacked?("attachments")
      @project.update!(stack_versions: nil)
      assert @project.reload.panel_layout.stacked?("attachments")
      refute @project.panel_layout.stacked?("tasks"), "a panel that draws no files never stacks"
    end
  end
end
