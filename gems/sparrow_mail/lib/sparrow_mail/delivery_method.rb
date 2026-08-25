# frozen_string_literal: true

module SparrowMail
  # The ActionMailer delivery method.
  #
  #   ActionMailer::Base.delivery_method = :sparrow_mail
  #
  # Registered automatically by the Railtie when Rails is present. With no
  # settings it delivers through the globally configured adapter, which is what
  # nearly every application wants. Settings naming an adapter build a separate
  # one, for the case where a single application talks to two providers:
  #
  #   config.action_mailer.delivery_method = :sparrow_mail
  #   config.action_mailer.sparrow_mail_settings = {
  #     adapter: :postmark,
  #     api_key: ENV["POSTMARK_SERVER_TOKEN"]
  #   }
  #
  # A note on `deliver_later`. ActiveJob retries failed jobs by default, and a
  # retried job re-runs the whole mailer, which sends the message again. This
  # gem cannot prevent that — it never sees the job — so an application queueing
  # transactional mail should configure the job class not to retry delivery
  # failures. The README covers it under "deliver_later and retries".
  class DeliveryMethod
    attr_reader :settings

    def initialize(settings = {})
      @settings = (settings || {}).to_h { |key, value| [key.to_sym, value] }
    end

    def deliver!(mail)
      adapter_for(mail).deliver!(mail)
    end

    # Mail sent through ActionMailer is routed by stream exactly as
    # SparrowMail.deliver! routes it, so a mailer marking itself broadcast
    # reaches the bulk sending identity rather than the transactional one.
    #
    # Settings naming an adapter opt out of routing entirely: they are an
    # explicit instruction to use one specific transport.
    def adapter_for(mail)
      return adapter if settings[:adapter]

      SparrowMail.adapter_for(SparrowMail::Envelope.stream_from(mail))
    end

    # Resolved per call rather than memoised, so that reconfiguring
    # SparrowMail at runtime is picked up by an already-registered delivery
    # method.
    def adapter
      return SparrowMail.adapter unless settings[:adapter]

      SparrowMail.registry
        .fetch(settings[:adapter])
        .new(settings.except(:adapter))
    end

    # Settings hold API keys.
    def inspect
      "#<SparrowMail::DeliveryMethod settings=#{settings.keys.inspect}>"
    end
    alias_method :to_s, :inspect
  end
end
