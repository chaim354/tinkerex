require "test_helper"

# The unlisted-project token travels as `?k=<128-bit token>` on every request to an unlisted page
# (Public::BaseController#unlisted_token_ok?). Rails logs request parameters, so the credential
# was written to the log on every visit until it joined filter_parameters.
#
# WHY A REGEXP AND NOT `:k`: ActiveSupport::ParameterFilter matches a String/Symbol entry as a
# SUBSTRING of the key (that is how `:passw` catches `password`), so a bare `:k` would redact
# `kind`, `block_id`, `node_ids`, every key containing a k. The second assertion pins that.
class ParameterFilterTest < ActiveSupport::TestCase
  def filtered(params)
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)
  end

  test "the unlisted token is filtered" do
    assert_equal "[FILTERED]", filtered({ "k" => "0123456789abcdef" })["k"]
  end

  test "keys that merely contain a k are not" do
    out = filtered({ "kind" => "thumbnail", "block_id" => "7", "node_ids" => "a,b" })
    assert_equal({ "kind" => "thumbnail", "block_id" => "7", "node_ids" => "a,b" }, out)
  end
end
