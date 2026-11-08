# frozen_string_literal: true
module DiscourseRsc
  # Public, credential-free UI shell. Does not inherit the forum's login redirect
  # and cannot access a wallet. The existing authenticated APIs remain unchanged.
  class ArcadeEmbedController < ::ActionController::Base
    def index
      return head :not_found unless SiteSetting.rsc_enabled && SiteSetting.rsc_arcade_enabled
      response.headers['Cache-Control'] = 'no-store'
      response.headers['X-Content-Type-Options'] = 'nosniff'
      response.headers['X-Frame-Options'] = 'SAMEORIGIN'
      response.headers['Referrer-Policy'] = 'same-origin'
      response.headers['Content-Security-Policy'] = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' https: data:; connect-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
      path = File.expand_path('../../../public/arcade/embed.html', __dir__)
      render html: File.read(path).html_safe, layout: false
    end
  end
end
