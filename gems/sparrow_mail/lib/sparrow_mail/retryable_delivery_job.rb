# frozen_string_literal: true

module SparrowMail
  # An ActionMailer delivery job that retries the failures worth retrying,
  # and only those. A mailer opts in:
  #
  #   class NewsletterMailer < ApplicationMailer
  #     self.delivery_job = SparrowMail::RetryableDeliveryJob
  #   end
  #
  # The gem's own send is never retried (see the README's "A send is never
  # retried") -- a retried send can arrive twice, which is exactly the wrong
  # trade for a sign-in code. `deliver_later` is a different layer: a retried
  # job re-runs the whole mailer, and for mail where a duplicate is a much
  # smaller problem than a missed send -- a newsletter, not an OTP -- that
  # trade is worth taking. This class is that opt-in; nothing uses it unless
  # a mailer names it.
  #
  # Only three of the gem's five failure categories are retried:
  # RateLimitError, ProviderError and NetworkError, because those are the
  # ones where sending again has a chance of working (see DeliveryError's
  # categories in errors.rb). AuthenticationError and InvalidRecipientError
  # are deliberately absent -- sending the same bad credential or the same
  # rejected address again changes nothing, so retrying would only delay a
  # failure that was never going to resolve.
  #
  # Mechanically, this works by outranking
  # ActionMailer::MailDeliveryJob's own `rescue_from StandardError`, which
  # otherwise hands every failure to the mailer class and re-raises.
  # ActiveJob searches retry_on/rescue_from handlers from the most recently
  # declared outward, so this subclass's handlers for these three classes are
  # checked before the ancestor's blanket one -- everything else still
  # behaves exactly as it did without this job.
  class RetryableDeliveryJob < ActionMailer::MailDeliveryJob
    RETRYABLE_ERRORS = [RateLimitError, ProviderError, NetworkError].freeze

    retry_on(*RETRYABLE_ERRORS, wait: :polynomially_longer, attempts: 5)
  end
end
