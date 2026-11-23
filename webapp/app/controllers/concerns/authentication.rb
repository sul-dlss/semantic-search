# frozen_string_literal: true

# Concern for handling authentication through the Envoy Gateway's OIDC filter.
#
# The gateway (see k8s/chart/templates/route.yaml) is configured so that:
# - /webauth/login requires an OIDC login. Thus, redirecting a user to it triggers login.
# - Requests that reach /webauth/login carry the AUTHENTICATED_HEADER, which the gateway sets on
#   that route only, overwriting any value the client sent.
# - OIDC_LOGOUT_PATH clears the gateway's OIDC session.
# - Other pages do not require authentication.
#
# Rails trusts the header only in AuthenticationController#login, and records the login in the
# session, so no other path can be spoofed with it.
module Authentication
  extend ActiveSupport::Concern

  MAX_URL_SIZE = ActionDispatch::Cookies::MAX_COOKIE_SIZE / 2
  AUTHENTICATED_HEADER = "X-Oidc-Authenticated"
  OIDC_LOGOUT_PATH = "/webauth/oidc/logout"

  included do
    helper_method :authenticated?
  end

  private

  # @return [Boolean] true if the user making this request has logged in.
  def authenticated?
    # In development there is no gateway in front of Rails, so set REMOTE_USER to simulate a login.
    return ENV["REMOTE_USER"].present? if Rails.env.development?

    session[:authenticated] == true
  end

  # Use as a before_action in controllers whose actions require a logged in user.
  def require_authentication
    request_authentication unless authenticated?
  end

  def request_authentication
    # Always check that we have enough space in the cookie to store the full return URL.
    #
    # This situation typically occurs when we are scanned for vulnerabilities and a
    # CRLF Injection attack is attempted, see https://www.geeksforgeeks.org/crlf-injection-attack/
    session[:return_to_after_authenticating] = request.url if request.url.size < MAX_URL_SIZE
    redirect_to main_app.login_path
  end

  # A return_to param lets a page that cannot write the session (such as a streamed chat answer)
  # link to login. url_from discards it unless it points back at this host.
  def after_authentication_url
    session.delete(:return_to_after_authenticating) || url_from(params[:return_to]) || root_url
  end
end
