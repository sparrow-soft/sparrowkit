# frozen_string_literal: true

module SparrowAuth
  # Every management page in this engine needs the same two things: a verified
  # account, and a session that has not been revoked.
  #
  # The second one is easy to leave out, and was. `rodauth.rails_account` reads
  # the signed cookie and answers who it names — which is a question about the
  # cookie, not about whether that session is still allowed to exist. Rodauth
  # runs its own active-session check on its own routes; these controllers are
  # Rails routes and never reached it.
  #
  # The effect was that revoking a session ended it everywhere except the pages
  # for managing passkeys, connections and sessions themselves. Somebody
  # revoking a session they did not recognise would have left it able to remove
  # their passkeys, which is precisely backwards.
  module RequiresLiveSession
    extend ActiveSupport::Concern

    included do
      before_action :require_live_session

      # Views need to say who is signed in — the back office prints it in the
      # bar on every page, on purpose. Guarded because this concern is included
      # by API controllers too, and ActionController::API has no helpers.
      helper_method :current_account if respond_to?(:helper_method)
    end

    private

    def current_account
      @current_account ||= rodauth.rails_account
    end

    # The session row holds an HMAC of the key in the cookie, so this recomputes
    # rather than comparing the key. Rodauth may return more than one while a
    # secret is being rotated; any of them being present means this session is
    # still live.
    def current_session_id
      return @current_session_id if defined?(@current_session_id)

      @current_session_id = begin
        key = rodauth.session[rodauth.session_id_session_key]
        if key.nil? || current_account.nil?
          nil
        else
          Array(rodauth.send(:compute_hmacs, key)).find { |hmac|
            current_account.sessions.exists?(session_id: hmac)
          }
        end
      end
    end

    def require_live_session
      raise UnverifiedAccount unless current_account&.verified?
      raise UnverifiedAccount if current_session_id.nil?
    end
  end
end
