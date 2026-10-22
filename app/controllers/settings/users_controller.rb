# ACCOUNTS, FOR AN ADMIN (2026-10-21; docs/superpowers/specs/2026-10-21-admin-users-design.md). The
# browser twin of the console doors in lib/tasks/tinkerex.rake: list every account, add one confirmed
# with a password the admin types, and on each other account's page reset its password, make or
# unmake it an admin, sign out one of its desktop devices, or delete it.
#
# EVERY ACCOUNT ON THE SERVER, NOT current_user's OWN ROWS: the one controller whose subject is other
# accounts, which is why its lookups are User.find and the gate comes first. A non-admin -- and the
# shared demo, whatever its row says (User#can_manage_accounts?) -- is sent back to Settings.
#
# NEVER THE SIGNED-IN ACCOUNT. Your password, your address and your deletion are the Account page's,
# behind your current password (Users::RegistrationsController); every member action here sends you
# there. That is also what keeps an admin on the server: the one acting always remains one, so
# demoting or deleting another account can never remove the last. The only door that could is the
# Account page's own delete, which refuses it.
module Settings
  class UsersController < ApplicationController
    before_action :require_account_manager!
    before_action :set_user, only: %i[edit reset_password set_admin revoke_device destroy]

    def index
      @users = User.order(:id).to_a
      @new_user = User.new
    end

    # POST /settings/users {user: {email, password, admin}}. Confirmed on the spot, as tinkerex:owner
    # does: the admin chose this person, and a self-hosted server usually has no mail to confirm by.
    def create
      @new_user = User.new(new_user_params.merge(confirmed_at: Time.current, admin: params.dig(:user, :admin) == "1"))
      if password_given?(@new_user, new_user_params[:password]) && @new_user.save
        # ON A SCANNABLE BACKEND (share, s3) EACH ACCOUNT HOLDS ITS OWN CATALOG OF THE ONE LIBRARY,
        # filled by Library::ScanJob per user, so without this the new account opens an empty library
        # until the next 15-minute sweep. No pending check: this page sits behind
        # require_library_folder!, so the folder is confirmed by construction.
        Library::ScanJob.enqueue_for(@new_user) if capabilities.scannable?
        redirect_to settings_users_path, status: :see_other,
                    notice: "Added #{@new_user.email}. Give them the password you set."
      else
        @users = User.order(:id).to_a
        render :index, status: :unprocessable_entity
      end
    end

    def edit; end

    # PATCH /settings/users/:id/reset_password {user: {password}}. Also confirms the account and
    # clears a lock left from before 2026-10-22, when failed attempts still locked accounts. Devise
    # keeps the password's salt in the session, so the account's other browser sessions end, and the
    # new password signs out its desktop devices too (User#revoke_devices_after_password_change),
    # which the page says.
    #
    # A REFUSED RESET PUTS THE ROW BACK BEFORE THE PAGE RE-RENDERS (found in review): the unlock and
    # the confirmation are assigned in memory before Devise validates the password, so without the
    # restore the page reported "unlocked" over an account the database still holds locked.
    def reset_password
      password = params.require(:user)[:password].to_s
      @user.assign_attributes(password:, locked_at: nil, failed_attempts: 0, unlock_token: nil)
      @user.confirmed_at ||= Time.current
      if password_given?(@user, password) && @user.save
        redirect_to edit_settings_user_path(@user), status: :see_other, notice: "New password set for #{@user.email}."
      else
        @user.restore_attributes(%i[locked_at failed_attempts unlock_token confirmed_at])
        render :edit, status: :unprocessable_entity
      end
    end

    # PATCH /settings/users/:id/set_admin {admin: "1"|"0"}: the state asked for, not a toggle, so a
    # double submit is harmless. The demo account is refused rather than flagged -- the flag would be
    # ignored (User#can_manage_accounts?), and a page reading "admin" over it would mislead.
    # `update_column`, not `update!`: a flag flip must not fail on an unrelated validation of an old row.
    def set_admin
      admin = params[:admin] == "1"
      if admin && Tinkerex::Demo.demo?(@user)
        return redirect_to edit_settings_user_path(@user), status: :see_other,
                           alert: "#{@user.email} is the shared demo account and cannot be an admin."
      end

      @user.update_column(:admin, admin)
      redirect_to edit_settings_user_path(@user), status: :see_other,
                  notice: admin ? "#{@user.email} is now an admin." : "#{@user.email} is no longer an admin."
    end

    # DELETE /settings/users/:id/devices/:device_id: signs one of this account's desktop devices out
    # (pentest H1b), the admin's twin of Settings::DevicesController#destroy. Found through @user, so
    # a device of any OTHER account 404s, and set_user has already sent the signed-in account to its
    # own pages. Deleting the row is the whole revocation (Device).
    def revoke_device
      device = @user.devices.find(params[:device_id])
      device.destroy!
      redirect_to edit_settings_user_path(@user), status: :see_other,
                  notice: "Signed #{device.name} out of #{@user.email}."
    end

    # DELETE /settings/users/:id {confirm_email}. The account's whole cascade (User's dependent: list,
    # kept complete by test/models/tenant_cleanup_test.rb), so the admin types its address first.
    # Files in the library are not part of it.
    def destroy
      unless params[:confirm_email].to_s.strip.downcase == @user.email
        @confirm_error = "Type #{@user.email} exactly to delete this account."
        return render :edit, status: :unprocessable_entity
      end

      @user.destroy!
      redirect_to settings_users_path, status: :see_other, notice: "Deleted #{@user.email}."
    end

    private

    def require_account_manager!
      return if current_user.can_manage_accounts?

      redirect_to settings_path, alert: "Only an admin can manage accounts.", status: :see_other
    end

    def set_user
      @user = User.find(params[:id])
      return unless @user == current_user

      redirect_to edit_user_registration_path, status: :see_other,
                  alert: "Your own account is changed here, behind your current password."
    end

    # `admin` IS READ ON ITS OWN in #create, never permitted here: a role key in a permit list is what
    # Brakeman's PermitAttributes check exists to catch, and `== "1"` says exactly what the checkbox
    # sends rather than leaving the cast to whatever the column accepts.
    def new_user_params = params.require(:user).permit(:email, :password)

    # A BLANK PASSWORD IS REFUSED HERE, NOT LEFT TO DEVISE: User#password_required? answers false when
    # there is neither a password nor a digest (the single sign-on seam), so a blank one would make a
    # new account nobody can sign in to, or "reset" a passwordless account to nothing, and report
    # success either way. True when the password may go on to validation.
    def password_given?(user, password)
      return true if password.to_s.present?

      user.errors.add(:password, :blank)
      false
    end
  end
end
