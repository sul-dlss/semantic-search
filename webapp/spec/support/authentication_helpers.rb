# frozen_string_literal: true

# Helpers to assist with authentication.
module AuthenticationHelpers
  # The header the gateway adds to requests for /webauth/login once the user has logged in with OIDC.
  def gateway_login_headers
    { Authentication::AUTHENTICATED_HEADER => "true" }
  end

  def sign_in(example: RSpec.current_example)
    if example.metadata[:type] == :system
      visit test_login_path
    else
      get test_login_path
    end
  end

  RSpec.configure do |config|
    config.include AuthenticationHelpers, type: :system
    config.include AuthenticationHelpers, type: :request
  end
end
