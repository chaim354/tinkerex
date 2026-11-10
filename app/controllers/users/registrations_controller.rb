# Devise registration (sign-up). :registerable + :confirmable means a new account is created
# unconfirmed and a confirmation email is sent; it cannot sign in until confirmed. The one
# exception is the server's FIRST account, the owner, confirmed on the spot (build_resource below).
module Users
  class RegistrationsController < Devise::RegistrationsController
    # Bounds automated signup floods (each one also sends a confirmation email). Deliberately
    # looser than the sign-in limit: a household or an office behind one NAT address may
    # legitimately create several accounts in a sitting.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> {
                 redirect_to new_user_registration_path,
                             alert: "Too many sign-up attempts. Try again later."
               }

    # CLOSED BY DEFAULT IN PRODUCTION, AND THE FIRST ACCOUNT IS THE OWNER (Tinkerex::Registration
    # has the argument). A closed server answers the sign-up page with a 403 that says so, rather
    # than a 404 that pretends the route does not exist — a visitor who was sent here by the
    # person running the box should learn to ask them, not to retype the address.
    before_action :require_registration_open!, only: %i[new create]

    # THE SHARED DEMO ACCOUNT KEEPS ITS ADDRESS, ITS PASSWORD AND ITS EXISTENCE (Tinkerex::Demo). Its
    # current password is random and told to nobody, so Devise would refuse both anyway; this says
    # why instead of "Current password is invalid", and holds for whoever does know it. After
    # Devise's prepended authenticate_scope!, so it reads the signed-in account; every other account
    # reaches Devise's update and the destroy below exactly as before.
    before_action :refuse_demo_account!, only: %i[update destroy]

    DEMO_ACCOUNT_REFUSAL = "This is the shared demo account: its email and password can't be " \
                           "changed and it can't be deleted. It resets every night.".freeze

    LAST_ADMIN_REFUSAL = "You are this server's only admin. Make another account an admin under " \
                         "Settings → Users before deleting yours.".freeze

    # The Delete section's two password refusals (#destroy), in the page's words rather than
    # Devise's "Current password is invalid".
    DELETE_PASSWORD_BLANK = "Type your password to delete this account.".freeze
    DELETE_PASSWORD_WRONG = "That is not your current password, so nothing was deleted.".freeze

    # A DELIVERY FAILURE MUST NOT LOOK LIKE A BROKEN APP, BECAUSE THE ACCOUNT ALREADY EXISTS.
    # Devise mails the confirmation from an `after_commit` on the user, so the row is COMMITTED
    # before the SMTP connection is even attempted. Production leaves `raise_delivery_errors` at
    # its framework default (true) and ships no `smtp_settings`, so on a self-hosted box with no
    # mail server — the product's primary deployment — signing up raised `Errno::ECONNREFUSED`
    # from `localhost:25` and rendered a 500, with the user PERSISTED and unconfirmed behind it.
    # Retrying then answered "email has already been taken", which is a complete lockout with no
    # path forward stated anywhere. Measured against the real settings, not reasoned about.
    #
    # `Net::SMTPError` is a MODULE mixed into every Net::SMTP exception class, so one entry covers
    # the authentication/syntax/server family; the Errno set covers "nothing is listening" and the
    # timeouts cover "something is, but not a mail server". Deliberately NOT `StandardError`: a
    # NoMethodError in a mailer template is a bug and must keep 500-ing rather than be laundered
    # into a friendly notice about email (§14a makes the same argument about rescuing too widely).
    MAIL_DELIVERY_ERRORS = [
      Net::SMTPError, Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT
    ].freeze

    rescue_from(*MAIL_DELIVERY_ERRORS) do |e|
      Rails.logger.error("sign-up confirmation email failed: #{e.class}: #{e.message}")
      redirect_to new_user_session_path, alert: <<~MSG.squish
        Your account was created, but the confirmation email could not be sent, so you cannot sign
        in yet. If you run this server, configure a mail server and then use "Didn't receive
        confirmation instructions?" below to send it again. Otherwise ask whoever runs it.
      MSG
    end

    # WHERE AN UNCONFIRMED SIGN-UP LANDS, AND THE DEFAULT LOSES ITS OWN MESSAGE ON THE WAY.
    # Devise sets the `signed_up_but_unconfirmed` notice and redirects to `root_path`. Root is
    # gated, so Warden bounces it to the sign-in page — and the notice is consumed by that
    # INTERMEDIATE request, which the user never sees. What survived to the page they do see was
    # the failure app's own alert: "You need to sign in or sign up before continuing", telling a
    # brand-new maker to do the thing they had just done. They could only learn the truth by
    # failing a login, which finally said the account was unconfirmed.
    #
    # Landing on the sign-in page directly means one redirect, no gated hop, and the notice
    # arrives. Guard: registration_flow_test.rb drives the real request and asserts the message.
    def after_inactive_sign_up_path_for(_resource) = new_user_session_path

    # A human web sign-up MUST supply a password. The model's `password_required?` returns
    # false whenever no password is set (so the OmniAuth seam + the device-token bootstrap can
    # create passwordless accounts), which means a blank-password web form would otherwise
    # persist an inert, can't-authenticate row. Reject that at the web boundary instead of
    # broadly flipping `password_required?` — which would break every programmatic passwordless
    # `User.create!` (from_omniauth, the v1 bootstrap, identity-backed accounts) and the suite.
    def create
      if params.dig(:user, :password).blank?
        build_resource(sign_up_params)
        resource.errors.add(:password, :blank)
        clean_up_passwords(resource)
        set_minimum_password_length
        respond_with_navigational(resource) { render :new, status: :unprocessable_entity }
        return
      end

      # THE FIRST ACCOUNT TRIGGERS THE FIRST SCAN (J, 2026-10-15): decided BEFORE super, because once
      # the owner exists first_owner? is false forever. Library::ScanJob.enqueue_first_for says why
      # this is a door's job and not a User callback. On a fresh share install the call is a no-op
      # until /settings/library confirms the folder (K §3); that confirmation makes the same call.
      first = Tinkerex::Registration.first_owner?
      super do |user|
        Library::ScanJob.enqueue_first_for(user) if first && user.persisted?
      end
    end

    # Devise's #destroy is a bare `resource.destroy` with no confirmation of any kind. Account
    # deletion here cascades through 24 `dependent:` associations (22 `:destroy`, plus 2
    # `:delete_all` where the child model refuses record-level destruction) — the whole library
    # catalog, projects, build log, sheets, previews, paired devices — and there is no undo.
    # Measured before this guard: one request carrying only a session cookie took users=1
    # projects=1 nodes=1 tasks=1 to zero.
    #
    # Require the current password, which is the same bar Devise already sets for merely
    # CHANGING a password. Deleting everything should not be the cheaper operation.
    #
    # NOT a `before_action`: the failure has to re-render the Account page, which needs the same
    # resource that #edit renders.
    #
    # A REFUSAL IS THE DELETE SECTION'S, NEVER THE RESOURCE'S (UX audit F2). Written onto
    # `resource.errors` it rendered at the top of the page, under the email-and-password form, while
    # the Delete section the maker had just used said nothing. `@delete_error` is read by that section
    # alone (users/registrations/edit), and the resource stays clean so the update form shows no error
    # it did not cause. Guard: account_page_test.rb ("a refused delete shows its error in the Delete section").
    def destroy
      # THE LAST ADMIN STAYS WHILE ANYONE ELSE IS HERE (2026-10-21): accounts are managed at Settings →
      # Users by an admin, so deleting the only one leaves accounts nobody can manage but a console.
      # This is the only door that can: Settings::UsersController never acts on the signed-in account.
      # Asked before the password, because no password makes it right. The sole account may still go,
      # and the demo account is not "anyone else": it can never be made an admin, so counting it would
      # keep an owner with only the demo beside them (OVH) from ever deleting their account.
      others = User.where.not(id: resource.id).where.not(email: Tinkerex::Demo.email.to_s)
      return refuse_delete(LAST_ADMIN_REFUSAL) if resource.last_account_manager? && others.exists?

      supplied = params.dig(:user, :current_password).to_s
      if resource.valid_password?(supplied)
        super
      else
        refuse_delete(supplied.blank? ? DELETE_PASSWORD_BLANK : DELETE_PASSWORD_WRONG)
      end
    end

    protected

    # SAVING LANDS BACK ON THE ACCOUNT PAGE (UX audit F1), with Devise's notice, rather than on Recent:
    # the maker was here to change something and should see it changed. A password change that does
    # not keep the session (Devise.sign_in_after_change_password off) still goes to sign-in, as
    # Devise's own answer does, because this page needs a session.
    def after_update_path_for(resource)
      sign_in_after_change_password? ? edit_user_registration_path : super
    end

    # The first account is the owner: confirmed on the spot, because a self-hoster has no mail server
    # on day one (Devise's own create path -- build, save, then branch on active_for_authentication?
    # -- signs a confirmed account straight in), and the admin who manages every account after it at
    # Settings → Users. Both must be set BEFORE save, which is why this hooks build_resource rather
    # than an after_create -- and the admin flag is decided here rather than in a User callback, which
    # would also make the demo account (minted alone by Tinkerex::DemoReset) and every test's first
    # user an admin. A later sign-up cannot ask for it: sign_up_params permits email and the two
    # passwords only. Protected, as Devise's own is: a public method on a controller is an action.
    def build_resource(hash = {})
      super
      # EVERY PERSON WHO SIGNS UP IS SHOWN THE ONBOARDING WIZARD ONCE (2026-11-09) — the owner and a
      # later sign-up alike, so this sits ABOVE the first-owner return. A door, not a User callback,
      # for the reason the admin flag is one: a callback would also mark the demo account and every
      # account the suite makes.
      resource.onboarding_pending = true
      return unless Tinkerex::Registration.first_owner?

      resource.skip_confirmation!
      resource.admin = true
    end

    private

    def refuse_delete(message)
      @delete_error = message
      clean_up_passwords(resource)
      set_minimum_password_length
      respond_with_navigational(resource) { render :edit, status: :unprocessable_entity }
    end

    def require_registration_open!
      return if Tinkerex::Registration.open?

      render "users/registrations/closed", status: :forbidden
    end

    def refuse_demo_account!
      return unless Tinkerex::Demo.demo?(current_user)

      redirect_to edit_user_registration_path, alert: DEMO_ACCOUNT_REFUSAL, status: :see_other
    end
  end
end
