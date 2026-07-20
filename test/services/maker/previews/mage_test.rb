require "test_helper"

module Maker
  module Previews
    class MageTest < ActiveSupport::TestCase
      setup { @mage = File.binread(Rails.root.join("test/fixtures/files/sample.mage")) }

      test "is always available (pure-Ruby embedded PNG extraction, no native dep)" do
        assert Maker::Previews::Mage.available?
      end

      test "claims the .mage extension" do
        assert_equal %w[mage], Maker::Previews::Mage::EXTENSIONS
        assert_equal Maker::Previews::Mage, Maker::Previews::Registry.for("mage")
      end

      test "renders the embedded thumbnail PNG" do
        result = Maker::Previews::Mage.render(@mage, size: 512)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end

      test "raises NoThumbnail when the MillMage file has no embedded thumbnail" do
        bare = %(<MillMageProject><Toolpaths/></MillMageProject>)
        assert_raises(Maker::Previews::Mage::NoThumbnail) do
          Maker::Previews::Mage.render(bare, size: 512)
        end
      end
    end
  end
end
