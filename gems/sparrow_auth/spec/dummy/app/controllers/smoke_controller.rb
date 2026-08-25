# frozen_string_literal: true

# The host application's side of the smoke run: a place to start, and a mailbox.
#
# This lives in the dummy application rather than in the engine, deliberately.
# A page that shows anyone every message the system has sent is exactly right for
# poking at a flow on your own machine and completely indefensible shipped inside
# an auth gem, where it would be a credential dump behind a URL. The boundary is
# the point: sparrow_auth cannot serve this even by accident.
class SmokeController < ActionController::Base
  layout "smoke"

  def index
    @accounts = SparrowAuth::Account.order(:id)
    @current_account = rodauth.rails_account

    # The enrollment prompt, in the host application because that is where it
    # belongs: the engine knows whether an account has a passkey, and the
    # application decides whether this is the moment to ask. Offered to somebody
    # signed in by any sign-in method who has not enrolled one, and not shown again once
    # they have — or once they have said no in this session.
    @offer_passkey =
      @current_account&.verified? &&
      !@current_account.passkey? &&
      !session[:passkey_offer_declined]
  end

  def decline_passkey
    session[:passkey_offer_declined] = true
    redirect_to root_path, notice: "We will not ask again this session"
  end

  # Reads sparrow_mail's in-process deliveries, which is where mail goes under
  # the test adapter. With real credentials configured the messages go to a real
  # inbox instead and this list stays empty, which is correct rather than broken.
  def mailbox
    @deliveries = SparrowMail.deliveries.reverse
  end

  def clear_mailbox
    SparrowMail.deliveries.clear
    redirect_to mailbox_path, notice: "Mailbox cleared"
  end

  # The rate limits are real and strict on purpose: one send per address per
  # minute. That is correct in production and tedious when you are clicking
  # through a flow by hand, so there is a button for it, in the host app, where
  # a real deployment would never put one.
  def clear_rate_limits
    SparrowAuth::AuthEvent.delete_all
    redirect_to root_path, notice: "Rate limit counters cleared"
  end
end
