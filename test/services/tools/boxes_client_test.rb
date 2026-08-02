require "test_helper"

class BoxesClientTest < ActiveSupport::TestCase
  test "configured? reflects BOXES_SIDECAR_URL" do
    with_env("BOXES_SIDECAR_URL" => nil) { assert_not Tools::BoxesClient.configured? }
    with_env("BOXES_SIDECAR_URL" => "http://boxes:8000") { assert Tools::BoxesClient.configured? }
  end

  private

  def with_env(vars)
    old = {}
    vars.each { |k, v| old[k] = ENV.key?(k) ? ENV[k] : :unset; v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    yield
  ensure
    old.each { |k, v| v == :unset ? ENV.delete(k) : (ENV[k] = v) }
  end
end
