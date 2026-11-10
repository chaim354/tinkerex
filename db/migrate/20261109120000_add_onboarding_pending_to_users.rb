# THE ONBOARDING WIZARD'S ONE PIECE OF STATE (2026-11-09; docs/superpowers/specs/
# 2026-11-09-onboarding-wizard-design.md). TRUE ONLY WHERE A DOOR SAYS SO: the four that make an
# account for a person — sign-up, Settings → Users, `tinkerex:owner` and a first OIDC sign-in — set
# it, and Skip or a project made in the wizard clears it (WelcomeController). THE DEFAULT IS FALSE,
# and that is the whole migration: every existing account, the nightly demo account and every
# account a test or a console makes stays off the wizard with no backfill. A person who already
# uses the app is never sent on a tour of it.
class AddOnboardingPendingToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :onboarding_pending, :boolean, null: false, default: false
  end
end
