require "test_helper"

module Maker
  module Addons
    # The permission vocabulary has ONE definition, for the same reason the capability map does
    # (CLAUDE.md §14d, "ONE file-type vocabulary"): a label table copied into a view drifts, and the
    # drift is invisible because both copies still render something.
    class PermissionsTest < ActiveSupport::TestCase
      test "a known permission gets a human label" do
        assert_equal "Write files to your library", Permissions.label_for("library:write")
      end

      # THE FALLBACK IS THE POINT. Manifests come from a source this process does not control, and a
      # newer addon may declare a permission this host has never heard of. Rendering blank would
      # make the card silently understate what the addon asked for — worse than showing a raw name.
      test "an unknown permission falls back to its own name rather than rendering blank" do
        assert_equal "data:read:machine-library/machines",
                     Permissions.label_for("data:read:machine-library/machines")
      end

      test "a parameterised service permission is labelled with the service it names" do
        assert_equal "Call the boxes service", Permissions.label_for("service:boxes")
      end

      test "every known name has a non-blank label" do
        Permissions::LABELS.each do |name, label|
          assert label.present?, "#{name} has a blank label"
        end
      end
    end
  end
end
