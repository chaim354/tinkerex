# Loud, visible warning whenever the test/dev signup seam is enabled. The seam
# (POST /v1/test/users) creates CONFIRMED accounts with NO email verification — appropriate
# for a self-hosted test/dev instance (e.g. the Unraid box) so automated tests + dev can
# enroll accounts, but NEVER for the real managed SaaS production. The seam is gated solely on
# ENABLE_TEST_SIGNUP (see app/controllers/v1/test_users_controller.rb + config/routes.rb), so
# this warning is the visibility backstop: if you ever see it on the managed prod, turn it off.
if ENV["ENABLE_TEST_SIGNUP"].present?
  msg = "⚠️  ENABLE_TEST_SIGNUP is ON — the unverified POST /v1/test/users signup seam is OPEN. " \
        "Non-production test/dev instances ONLY. Never set this on the managed SaaS."
  Rails.logger&.warn(msg)
  warn(msg) # also to STDERR so it shows in container logs even before the logger is wired
end
