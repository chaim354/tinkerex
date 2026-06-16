# Devise session controller. Default behavior (authenticate email+password, reject
# unconfirmed via :confirmable, reject locked via :lockable). Subclassed so we can keep our
# routing namespace and add hooks later. No overrides needed today.
module Users
  class SessionsController < Devise::SessionsController
  end
end
