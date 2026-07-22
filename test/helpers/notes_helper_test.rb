require "test_helper"

class NotesHelperTest < ActionView::TestCase
  test "renders markdown formatting to HTML" do
    html = render_note("**bold** and [link](http://example.com)")
    assert_includes html, "<strong>bold</strong>"
    assert_match %r{<a[^>]+href="http://example.com"}, html
  end

  test "renders a list" do
    assert_includes render_note("- one\n- two"), "<li>one</li>"
  end

  # The security assertion — the whole reason render_note sanitizes.
  test "strips a <script> tag (stored XSS)" do
    html = render_note("hi <script>alert('x')</script>")
    assert_not_includes html.downcase, "<script"
  end

  test "strips a javascript: href" do
    assert_not_includes render_note("[x](javascript:alert(1))"), "javascript:"
  end
end
