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

      super
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
    # NOT a `before_action`: the failure has to re-render the settings page with the error
    # attached to the resource, which needs the same resource that #edit renders.
    def destroy
      supplied = params.dig(:user, :current_password).to_s
      if resource.valid_password?(supplied)
        super
      else
        resource.errors.add(:current_password, supplied.blank? ? :blank : :invalid)
        clean_up_passwords(resource)
        set_minimum_password_length
        respond_with_navigational(resource) { render :edit, status: :unprocessable_entity }
      end
    end

    protected

    # The first account is confirmed on the spot: a self-hoster has no mail server on day one,
    # and Devise's own create path (build, save, then branch on active_for_authentication?)
    # signs a confirmed account straight in. skip_confirmation! must run BEFORE save, which is
    # why this hooks build_resource rather than an after_create. Protected, as Devise's own is:
    # a public method on a controller is an action.
    def build_resource(hash = {})
      super
      resource.skip_confirmation! if Tinkerex::Registration.first_owner?
    end

    private

    def require_registration_open!
      return if Tinkerex::Registration.open?

      render "users/registrations/closed", status: :forbidden
    end
  end
end
