require "test_helper"

# THIS APP IS NOT A BROADCASTER, and these three guards are what keeps that from being re-derived.
#
# ActionCable shipped here as scaffold plus one hand-written Connection that authenticated a
# WebSocket with a device token. Nothing ever used it: no channel class, no `stream_from`, no
# `broadcast_to`, no `createConsumer` in any pack. The one caller it was built for — the sync
# daemon's `{head_seq}` nudge — attaches to the standalone sync server (chaim354/tinkerex-sync,
# which has its own channel and its own cable config on the `sync` accessory), and since Arc D
# Part 2 this app routes none of the /v1 sync endpoints a cable-attached device would need. So the
# surface was a door with a lock, a key nobody carries, and nothing behind it.
#
# THE OBVIOUS PROBE IS A GUARD THAT CANNOT FAIL, which is why none of the three below is it:
# `get "/cable"` answers 404 whether or not the mount exists, because ActionCable::Server::Base#call
# 404s every non-upgrade request itself. That is CLAUDE.md §15's "a guard that has never failed has
# not been shown to work" in its purest form — the assertion is true for the wrong reason.
#
# Re-adding a cable surface is not forbidden; going back to a DEVICE-TOKEN cable connection on this
# app is. If a future feature needs live push to a browser, it needs session auth and a channel
# that something subscribes to — at which point these guards are what you edit, deliberately.
class CableAbsentTest < ActiveSupport::TestCase
  # Not `recognize_path`: §15 records it as the wrong instrument for a mounted engine (it reports
  # the engine's own route for a proc endpoint). The route SET is the honest question here.
  test "no route mounts ActionCable" do
    mounts = Rails.application.routes.routes.map { |r| r.path.spec.to_s }
    refute_empty mounts, "the route set is empty — this guard would scan nothing (§14e)"
    assert_empty mounts.grep(%r{\A/cable}),
                 "/cable is mounted again. This app has no channel and no subscriber; a device's " \
                 "sync nudge comes from chaim354/tinkerex-sync, not from here."
  end

  # Emptiness IS the claim, so the anchor proves the instrument rather than the subject — §14e
  # records two architecture guards that went silently vacuous when the directory they globbed left.
  test "this app defines no ActionCable channel or connection" do
    anchor = Dir.glob(Rails.root.join("app", "controllers", "**", "*.rb"))
    refute_empty anchor, "glob machinery or Rails.root is wrong — this guard would pass over nothing"
    assert_empty Dir.glob(Rails.root.join("app", "channels", "**", "*.rb")),
                 "app/channels is back. A channel here needs SESSION auth and a real subscriber; " \
                 "the device-token Connection that used to live here had neither."
  end

  # A file-text assertion, because the knob's effect is not observable from the test environment:
  # config/environments/test.rb never set it, so resolving `config.action_cable` here would report
  # the same thing with the line present and absent.
  test "request-forgery protection is not disabled for a cable that no longer exists" do
    %w[production development].each do |env|
      body = File.read(Rails.root.join("config", "environments", "#{env}.rb"))
      refute_empty body, "config/environments/#{env}.rb is empty — this guard scans nothing"
      assert_nil body[/disable_request_forgery_protection/],
                 "config/environments/#{env}.rb turns off cable CSRF protection for a mount that " \
                 "is gone. It was justified by a token-authed connection; there is no connection."
    end
  end
end
