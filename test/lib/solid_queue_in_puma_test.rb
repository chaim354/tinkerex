require "test_helper"

# Background work (scans, previews, purges, intake, the changelog pull) runs in Solid Queue, and
# until 2026-10-13 it ran only when SOLID_QUEUE_IN_PUMA was set to anything at all — so a stranger's
# container did none of it, silently. On by default in production; false/0/no is a real off-switch
# for a split bin/jobs container; outside production the old opt-in stays.
class SolidQueueInPumaTest < ActiveSupport::TestCase
  def on?(env, production:) = Tinkerex::SolidQueueInPuma.enabled?(env, production:)

  test "on by default in production, off by default elsewhere" do
    assert on?({}, production: true)
    assert_not on?({}, production: false)
  end

  test "an explicit value wins in every environment" do
    assert on?({ "SOLID_QUEUE_IN_PUMA" => "true" }, production: false)
    assert on?({ "SOLID_QUEUE_IN_PUMA" => "1" }, production: false)
    %w[false 0 no False].each do |off|
      assert_not on?({ "SOLID_QUEUE_IN_PUMA" => off }, production: true), off
    end
  end
end
