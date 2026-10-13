# frozen_string_literal: true

module SparrowAuth
  # Replaces the cached list of Tor exits that SignIn.request checks before it
  # sends any mail. See SparrowAuth::TorExits.
  #
  # Schedule it hourly with whatever your application already uses for
  # recurring jobs. Until it has run once nothing is listed, and the check is
  # off.
  #
  # A failed download raises, so your error tracker hears about it, and leaves
  # the old list in force. There is no point retrying it sooner than the next
  # hourly run.
  class RefreshTorExitsJob < ActiveJob::Base
    # Sidekiq's own retries would race the next scheduled run. Only present
    # when Sidekiq is the queue adapter.
    sidekiq_options retry: false if respond_to?(:sidekiq_options)

    def perform
      count = TorExits.refresh!
      SparrowAuth.logger&.info("[sparrow_auth] tor_exits refreshed count=#{count}")
    end
  end
end
