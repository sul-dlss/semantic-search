# frozen_string_literal: true

# Controller for login and logout. See the Authentication concern for the methods used below.
class AuthenticationController < ApplicationController
  # The gateway requires an OIDC login before this action is reached, and sets the
  # AUTHENTICATED_HEADER. Without the header, login isn't set up in front of this app.
  def login
    unless request.headers[AUTHENTICATED_HEADER] == "true"
      render plain: "Login is not available.", status: :service_unavailable
      return
    end

    session[:authenticated] = true
    redirect_to after_authentication_url
  end

  # Lets specs log in without the gateway. This endpoint is only available in the test environment.
  def test_login
    session[:authenticated] = true

    head :ok
  end

  def logout
    session.delete(:authenticated)
    redirect_to OIDC_LOGOUT_PATH
  end
end
