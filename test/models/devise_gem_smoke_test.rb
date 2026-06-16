require "test_helper"

# Confirms the Devise gem is loaded and its generator constant is available before we wire
# the model. Removed once `User` actually `devise`s (Task 4 supersedes this), but harmless.
class DeviseGemSmokeTest < ActiveSupport::TestCase
  test "Devise is loaded" do
    assert defined?(Devise), "Devise constant should be defined after bundling the gem"
  end

  test "OmniAuth is loaded" do
    assert defined?(OmniAuth), "OmniAuth constant should be defined after bundling the gem"
  end
end
