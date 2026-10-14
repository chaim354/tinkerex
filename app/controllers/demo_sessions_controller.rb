# POST /demo -- the public demo's one click (Tinkerex::Demo; H, 2026-10-14). Signs the visitor into the
# shared demo account with a plain Devise session -- no remember-me cookie, so closing the browser
# ends it -- and lands them where any sign-in lands.
#
# A DEVISE CONTROLLER, NOT AN ApplicationController ONE WITH A SKIP. Every ApplicationController
# descendant must run `authenticate_user!` (test/architecture_invariants_test.rb, CLAUDE.md §14d),
# and Devise's own controllers are excluded from that by construction because a sign-in has to be
# reachable signed out. This IS a sign-in, so it stands where the others do rather than earning a
# `skip_before_action`. Being one is also why its route sits inside `devise_scope :user`
# (config/routes.rb): that is where `sign_in` gets its mapping.
#
# 404 WHEN THERE IS NO DEMO. The route is drawn on every deployment and answers as if it were not,
# which is what "nothing of it exists" means for a URL. On but with no account is an operator's
# unfinished setup (the sign-in page shows no button then), so that case is also logged -- the 404 is
# all a visitor should see of it.
class DemoSessionsController < DeviseController
  # Per IP. Each click is a sign-in that writes the shared row (trackable), so an unthrottled door is a
  # write per request for anyone with a loop. Twenty a minute is far past a person and well inside a
  # classroom behind one NAT address. Counts in config.action_controller.cache_store, as
  # Users::SessionsController's limit does.
  rate_limit to: 20, within: 1.minute, only: :create,
             with: -> {
               redirect_to new_user_session_path,
                           alert: "Too many demo sign-ins from your network. Try again in a minute."
             }

  def create
    return head(:not_found) unless Tinkerex::Demo.enabled?

    account = Tinkerex::Demo.account
    if account.nil?
      Rails.logger.warn("[demo] DEMO_ACCOUNT_EMAIL names no account, so POST /demo answers 404. " \
                        "Create it with: bin/rails tinkerex:demo:setup")
      return head(:not_found)
    end

    # THE SHARED-LIBRARY REFUSAL, AT THE FRONT DOOR. On share and s3 every account indexes the one
    # library, so signing a stranger into the demo beside another account hands them that account's
    # files -- the condition the nightly reset refuses too (Tinkerex::DemoReset). The page shows no
    # button in this state (Tinkerex::Demo.available?); a hand-posted click meets the same answer.
    others = Tinkerex::DemoReset.accounts_sharing_library(except: account)
    if others.positive?
      Rails.logger.warn("[demo] #{others} other #{others == 1 ? 'account shares' : 'accounts share'} " \
                        "the demo's library, so POST /demo answers 404 until they are removed")
      return head(:not_found)
    end

    # LOCKABLE MUST NOT BECOME AN OFF SWITCH FOR THE DEMO. The address is public and lockable counts
    # wrong passwords per ACCOUNT, so ten bad tries at the ordinary sign-in form would lock this one
    # for an hour, and Devise's activatable hook would then refuse every visitor's click below. The
    # lock guards a password, and nobody signs into the demo with one: this click is the way in.
    account.unlock_access! if account.access_locked?
    # As Devise's own SessionsController#create does before a sign-in: a fresh session is never a
    # timed-out one.
    request.env["devise.skip_timeout"] = true
    sign_in(:user, account)
    redirect_to after_sign_in_path_for(account), status: :see_other
  end
end
