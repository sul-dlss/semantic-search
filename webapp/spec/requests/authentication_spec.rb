# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authentication", type: :request do
  def header_links
    get "/documentation"
    Nokogiri::HTML(response.body).css("header a").map { |link| link["href"] }
  end

  describe "GET /webauth/login" do
    it "redirects to the root" do
      get "/webauth/login", headers: gateway_login_headers

      expect(response).to redirect_to(root_path)
    end

    it "returns to a page on this site named by return_to" do
      get "/webauth/login", params: { return_to: "/chat?q=frogs" }, headers: gateway_login_headers

      expect(response).to redirect_to("/chat?q=frogs")
    end

    it "ignores a return_to that points off-site" do
      get "/webauth/login", params: { return_to: "https://evil.example.com/" }, headers: gateway_login_headers

      expect(response).to redirect_to(root_path)
    end

    it "logs the user in for later requests" do
      get "/webauth/login", headers: gateway_login_headers

      expect(header_links).to include("/webauth/logout")
    end

    it "refuses the login when the gateway didn't add its header" do
      get "/webauth/login"

      expect(response).to have_http_status(:service_unavailable)
      expect(header_links).not_to include("/webauth/logout")
    end
  end

  describe "the gateway header on other paths" do
    it "doesn't log the user in" do
      get "/documentation", headers: gateway_login_headers

      page = Nokogiri::HTML(response.body)
      expect(page.css("header a").map { |link| link["href"] }).not_to include("/webauth/logout")
    end
  end

  describe "GET /webauth/logout" do
    it "logs the user out and redirects to the gateway's OIDC logout" do
      sign_in

      get "/webauth/logout"

      expect(response).to redirect_to(Authentication::OIDC_LOGOUT_PATH)
      expect(header_links).not_to include("/webauth/logout")
    end
  end

  describe "header links" do
    it "shows a login link when not authenticated" do
      get "/documentation"

      page = Nokogiri::HTML(response.body)
      expect(page.css('header a[href="/webauth/login"]').map(&:text)).to eq %w[Login Login]
      expect(page.css('header a[href="/webauth/logout"]')).to be_empty
    end

    it "shows a logout link when authenticated" do
      sign_in

      get "/documentation"

      page = Nokogiri::HTML(response.body)
      expect(page.css('header a[href="/webauth/logout"]').map(&:text)).to eq %w[Logout Logout]
      expect(page.css('header a[href="/webauth/login"]')).to be_empty
    end
  end
end
