module Tools
  # Shared base for every addon's web UI. Session-authed like the rest of the web app.
  class BaseController < ApplicationController
    before_action :authenticate_user!
  end
end
