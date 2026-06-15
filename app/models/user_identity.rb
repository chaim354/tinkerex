# OmniAuth seam (docs/parity-roadmap.md §A). Links an external OAuth/OIDC account
# (provider + uid) to a local User. Created by `User.from_omniauth`. No provider is wired
# yet — this is the additive-login-method anchor for later OIDC/SSO.
class UserIdentity < ApplicationRecord
  belongs_to :user

  validates :provider, presence: true
  validates :uid, presence: true, uniqueness: { scope: :provider }
end
