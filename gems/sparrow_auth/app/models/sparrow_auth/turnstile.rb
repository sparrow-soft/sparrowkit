# frozen_string_literal: true

require "digest"
require "json"
require "net/http"

module SparrowAuth
  # Cloudflare Turnstile: the check that a form which sends mail to an address
  # somebody typed was filled in by a browser with a person at it.
  #
  #   # in the form, before the submit button
  #   <%= SparrowAuth::Turnstile.widget(action: "login") %>
  #
  #   # in the controller, before SparrowAuth::SignIn.request
  #   unless SparrowAuth::Turnstile.passed?(request, action: "login")
  #     return redirect_to sign_in_path, alert: SparrowAuth::Turnstile::REFUSAL_MESSAGE
  #   end
  #
  # It exists because a bot spent October 2026 posting other people's addresses
  # into every form that sends mail, from a new Tor exit each time. Every code
  # it asked for landed in a stranger's inbox, and every stranger who marks one
  # as spam costs the sending domain reputation that real sign-in codes depend
  # on. The rate limits in SignIn stop one address or one IP being used
  # repeatedly; they do nothing about many addresses from many IPs.
  #
  # Failing this check is said out loud, unlike everything else on the sign-in
  # path. That is safe because it is a question about the browser, not about
  # the address: the same answer comes back for every address, and it tells a
  # visitor nothing about whether an account exists.
  #
  # Rodauth's own create-account and resend-confirmation pages are checked by
  # rodauth_main.rb, which is the only place that can reach them -- they run as
  # middleware, above any controller of yours.
  #
  # Off until both keys are set (config.turnstile_site_key and
  # config.turnstile_secret_key, normally from the control panel). Off means no
  # widget and no check, so development and a test suite make no third-party
  # round trip.
  module Turnstile
    SITEVERIFY_URL = URI("https://challenges.cloudflare.com/turnstile/v0/siteverify")

    # The field the widget leaves its token in. Cloudflare's name, not ours.
    TOKEN_FIELD = "cf-turnstile-response"

    # Cloudflare documents tokens as at most 2048 characters.
    MAX_TOKEN_LENGTH = 2048

    # A token Cloudflare has vouched for is good for five minutes. Remembering
    # that it was used for twice as long means it can never be used again
    # while it could still pass.
    CLAIM_TTL = 10.minutes

    REFUSAL_MESSAGE = "We couldn’t confirm you’re a person. Please try again."

    module_function

    def enabled? = SparrowAuth.config.turnstile?

    def site_key = SparrowAuth.config.turnstile_site_key.presence

    def secret_key = SparrowAuth.config.turnstile_secret_key.presence

    # Where the script that draws the widget is served. See RodauthApp.
    def script_path = "#{SparrowAuth.config.path_prefix}/turnstile-js"

    # The widget, for inside a form, just before its submit button. An empty
    # string when Turnstile is off, so a form can render it unconditionally.
    #
    # `action` names the form ("login", "signup") and travels inside the token,
    # so a token solved on one form is refused by another.
    #
    # The script holds the form's submit buttons until a token arrives, and
    # gives them back if the widget cannot load at all, so the server's answer
    # explains a blocked check rather than a button that never works.
    def widget(action:)
      return "".html_safe unless enabled?

      h = ERB::Util.method(:html_escape)
      (%(<div data-sparrow-auth-turnstile data-sitekey="#{h.call(site_key)}" data-action="#{h.call(action)}"></div>) +
        %(<script src="#{h.call(script_path)}" defer></script>)).html_safe
    end

    # True when Turnstile is off, or on and satisfied by this request's token
    # for this action on this host.
    def passed?(request, action:)
      return true unless enabled?

      verify(
        token: request.params[TOKEN_FIELD],
        action: action,
        hostname: request.host,
        remote_ip: request.remote_ip
      )
    end

    # True only when Cloudflare vouches for this exact token, action and
    # hostname, and the token has not been used here before. Anything else --
    # no token, a malformed one, a timeout, a 5xx, a body that is not JSON -- is
    # false: a form that sends mail to an address somebody typed fails closed.
    #
    # The hostname check matters because one widget can be registered for
    # several domains, and a token solved on any of them would otherwise be good
    # here.
    def verify(token:, action:, hostname:, remote_ip:)
      return false unless token.is_a?(String) && token.present? && token.length <= MAX_TOKEN_LENGTH

      unless claim(token)
        log(:info, "refused action=#{action} errors=already-used")
        return false
      end

      result = siteverify(secret: secret_key, response: token, remoteip: remote_ip)

      passed = result["success"] == true && result["action"] == action && result["hostname"] == hostname
      log(:info, "refused action=#{action} errors=#{Array(result["error-codes"]).join(",")}") unless passed
      passed
    rescue => e
      log(:warn, "siteverify_failed class=#{e.class}")
      false
    end

    # Cloudflare says siteverify refuses a token it has already answered for.
    # It was seen accepting one production token three times in three minutes,
    # so a token is also claimed here, before Cloudflare is asked -- which means
    # two requests racing with one token cannot both reach it, and a token
    # Cloudflare refused cannot be tried again either.
    #
    # Only a digest is stored. If the cache cannot answer, the claim fails open
    # and Cloudflare's own check is what remains: a cache outage must not stop
    # everybody signing in.
    def claim(token)
      stored = Rails.cache.write(
        "sparrow_auth/turnstile/#{Digest::SHA256.hexdigest(token)}", true,
        unless_exist: true, expires_in: CLAIM_TTL
      )
      return stored unless stored.nil?

      log(:warn, "claim_failed cache_write_returned_nil")
      true
    rescue => e
      log(:warn, "claim_failed class=#{e.class}")
      true
    end

    def siteverify(params)
      response = Net::HTTP.start(SITEVERIFY_URL.host, SITEVERIFY_URL.port,
        use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
        post = Net::HTTP::Post.new(SITEVERIFY_URL)
        post.set_form_data(params.compact)
        http.request(post)
      end
      raise Error, "siteverify answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end

    def log(level, message)
      SparrowAuth.logger&.public_send(level, "[sparrow_auth] turnstile #{message}")
    end
  end
end
