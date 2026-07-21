require "test_helper"

module Tools
  class BoxesHelperTest < ActionView::TestCase
    test "box_help splits a trailing markdown manual link into [text, url]" do
      text, url = box_help("thickness of the material (in mm) " \
                           "[🛈](https://florianfesti.github.io/boxes/html/usermanual.html#thickness)")
      assert_equal "thickness of the material (in mm)", text
      assert_equal "https://florianfesti.github.io/boxes/html/usermanual.html#thickness", url
    end

    test "box_help leaves plain help untouched (no manual link)" do
      text, url = box_help("label the parts (where available)")
      assert_equal "label the parts (where available)", text
      assert_nil url
    end

    test "box_help does not mistake ordinary parentheses for a link" do
      help = "burn correction (in mm)(bigger values for tighter fit)"
      text, url = box_help(help)
      assert_equal help, text
      assert_nil url
    end

    test "box_help tolerates nil" do
      text, url = box_help(nil)
      assert_equal "", text
      assert_nil url
    end

    test "box_prefill_path nests params under params[] (not flattened by url_for's :params option)" do
      href = box_prefill_path("ABox", { "x" => "999", "y" => "7" })
      assert_includes href, "generator=ABox"
      assert_includes href, "params%5Bx%5D=999"
      assert_includes href, "params%5By%5D=7"
      refute_match(/[?&]x=999/, href) # must NOT be flattened to a top-level x=
    end

    test "box_prefill_path tolerates nil params" do
      assert_includes box_prefill_path("ABox", nil), "generator=ABox"
    end
  end
end
