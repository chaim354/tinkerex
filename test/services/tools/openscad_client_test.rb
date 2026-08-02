require "test_helper"

class OpenscadClientTest < ActiveSupport::TestCase
  test "configured? reflects OPENSCAD_SIDECAR_URL" do
    with_env("OPENSCAD_SIDECAR_URL" => nil) { assert_not Tools::OpenscadClient.configured? }
    with_env("OPENSCAD_SIDECAR_URL" => "http://openscad:8000") { assert Tools::OpenscadClient.configured? }
  end

  test "configured? is false for a BLANK url, not just a missing one" do
    # deploy.ovh.yml clears the sidecar URLs by setting them to "" (Task 1) — Kamal deep-merges
    # env.clear, so blanking is the only way to un-inherit. If blank read as configured, that
    # overlay would report the addon available and then fail on every call.
    with_env("OPENSCAD_SIDECAR_URL" => "") { assert_not Tools::OpenscadClient.configured? }
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
