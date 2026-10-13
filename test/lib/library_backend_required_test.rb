require "test_helper"

# With LIBRARY_BACKEND blank, production used to boot and then answer 500 to EVERY request,
# including /up: the CSP header's connect_src lambda calls FileLayer.current on every response,
# which raises inside middleware. The boot now refuses instead — in production only (an
# unconfigured development box must still boot, CLAUDE.md §14a), and not during the image build's
# assets:precompile, which Rails marks with SECRET_KEY_BASE_DUMMY.
class LibraryBackendRequiredTest < ActiveSupport::TestCase
  def required!(env, production: true) = LibraryBackendCheck.required_in_production!(env: env, production: production)

  test "a blank backend is refused in production, naming the three values" do
    e = assert_raises(LibraryBackendCheck::Error) { required!({}) }
    assert_match(/share \| s3 \| chunk_remote/, e.message)
    assert_raises(LibraryBackendCheck::Error) { required!({ "LIBRARY_BACKEND" => " " }) }
  end

  test "a set backend, a non-production boot, and the precompile boot all pass" do
    assert_nil required!({ "LIBRARY_BACKEND" => "share" })
    assert_nil required!({}, production: false)
    assert_nil required!({ "SECRET_KEY_BASE_DUMMY" => "1" })
  end
end
