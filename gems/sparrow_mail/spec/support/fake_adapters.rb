# frozen_string_literal: true

# Adapters used to exercise SparrowMail::Adapters::Base itself, independent of
# any real provider. They count their own invocations, because "the core calls
# an adapter exactly once" is the mechanism behind the never-retry rule and has
# to be asserted directly rather than inferred.
module FakeAdapters
  class Counting < SparrowMail::Adapters::Base
    adapter_name :counting

    class << self
      attr_accessor :calls, :raise_with, :native_sandbox

      def reset!
        self.calls = 0
        self.raise_with = nil
        self.native_sandbox = false
      end

      def native_sandbox?
        native_sandbox
      end
    end

    reset!

    def deliver_envelope(envelope)
      self.class.calls += 1
      raise self.class.raise_with if self.class.raise_with

      SparrowMail::Result.new(
        adapter: self.class.adapter_name,
        message_id: "fake-message-id",
        recipients: envelope.all_recipients.size
      )
    end
  end

  # Declares no deliver_envelope at all, to prove Base refuses to pretend.
  class Abstract < SparrowMail::Adapters::Base
    adapter_name :abstract
  end

  class RequiringSettings < SparrowMail::Adapters::Base
    adapter_name :requiring_settings
    required_settings :api_key, :domain

    def deliver_envelope(_envelope)
      SparrowMail::Result.new(adapter: self.class.adapter_name)
    end
  end
end

RSpec.configure do |config|
  config.before { FakeAdapters::Counting.reset! }
end
