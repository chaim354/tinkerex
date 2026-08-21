# frozen_string_literal: true

require "test_helper"

# THE HOST AND THE ENGINE EACH SHIP A COPY OF BEARER DEVICE-TOKEN AUTH, AND THIS IS WHAT STOPS THEM
# DRIFTING.
#
# The duplication is structural, not lazy: on share/s3 the engine is not loaded, so the host cannot
# include `Sync::V1::Authentication`; in a bare engine mount there is no host, so the engine cannot
# include `V1::Authentication`. Neither can be the single definition, and a shared third gem for
# twelve lines whose only real dependency (`Device`) the HOST already owns would be worse than the
# problem. So: two copies, and a test that fails when they stop agreeing -- the same answer
# test/engine_schema_test.rb uses for db/engine_schema.rb.
#
# COMPARES THE METHOD BODIES, NOT THE FILES. The two differ legitimately in namespace, in comments,
# and in nothing else that matters; comparing whole files would fail on every comment edit and
# teach the next person to delete the test.
class V1AuthParityTest < ActiveSupport::TestCase
  HOST = Rails.root.join("app/controllers/concerns/v1/authentication.rb")

  def engine_copy
    spec = Gem.loaded_specs["tinkerex-sync"]
    Pathname.new(spec.gem_dir).join("app/controllers/concerns/sync/v1/authentication.rb")
  end

  # Strip comments, blank lines and leading indentation, so what remains is the executable shape.
  def normalise(path)
    path.readlines
        .reject { |l| l.strip.empty? || l.strip.start_with?("#") }
        .map(&:strip)
        .reject { |l| l.start_with?("module ") || l == "end" }
        .join("\n")
  end

  test "the host's device auth and the engine's are the same implementation" do
    skip "the engine is not loaded on this leg" unless defined?(Sync)

    assert HOST.exist?, "the host's own auth concern is missing -- v1/maker/* cannot authenticate"
    assert engine_copy.exist?, "the gem ships no auth concern -- a bare mount cannot authenticate"

    assert_equal normalise(engine_copy), normalise(HOST),
                 "the two copies of device-token auth have drifted. They are duplicated by " \
                 "necessity (neither side can require the other in the case that matters), so a " \
                 "change to one must be made to the other in the same commit. Host: #{HOST}; " \
                 "engine: #{engine_copy}."
  end

  test "the host's concern is what V1::BaseController actually includes" do
    # Parity is worth nothing if the host stopped using its own copy.
    skip "the engine is not loaded on this leg" unless defined?(Sync)

    assert V1::BaseController.include?(::V1::Authentication)
    assert_not V1::BaseController.include?(Sync::V1::Authentication),
               "V1::BaseController includes the ENGINE's concern -- that is the dependency this " \
               "arc removed, and share/s3 cannot load it"
  end
end
