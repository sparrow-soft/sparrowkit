# frozen_string_literal: true

module SparrowMail
  module Console
    # What to do with sparrow_mail once it is configured.
    #
    # Built from what is actually stored. "Configure a provider" helps nobody;
    # "transactional mail goes through Postmark, broadcast through Mailgun, so
    # set the stream header on bulk mail" produces code that fits this
    # application.
    #
    # NO SECRETS. This text is written to be pasted into somebody else's chat
    # window. It names providers and says whether a key is set; it never says
    # what the key is.
    class Guide
      def initialize(settings = ::SparrowUi::Console::Settings, registry: SparrowMail.registry)
        @settings = settings
        @registry = registry
      end

      attr_reader :settings, :registry

      def stored
        @stored ||= settings.read(SparrowMail::CREDENTIALS_KEY)
      end

      def to_h
        {steps: steps, brief: brief}
      end

      # How to USE this, not how to install it. The delivery method line was
      # written by the installer before this page could be reached at all, and
      # telling somebody to add it again describes work already done.
      def steps
        [
          "# Any ordinary mailer sends through the configured provider\nUserMailer.welcome(account).deliver_later",
          broadcast? ? "# Bulk mail goes on its own stream, with its own reputation\nheaders[\"X-Sparrow-Stream\"] = \"broadcast\"\nmail(to: ..., subject: ...)" : nil,
          "# In tests and sandbox mode, messages land here instead\nSparrowMail.deliveries"
        ].compact
      end

      def brief
        <<~BRIEF.strip
          ## Mail (sparrow_mail)

          A delivery layer under ActionMailer. Mailers are ordinary
          ActionMailer classes; sparrow_mail decides which provider each message
          leaves by.

          Configuration in this app right now:
          - Transactional provider: #{provider_for(:transactional)}
          - Broadcast provider: #{broadcast? ? provider_for(broadcast_stream) : "none -- one provider handles both kinds"}
          - Default sender: #{stored[:default_from].presence || "not set"}

          What you get:
          - `config.action_mailer.delivery_method = :sparrow_mail`, then every
            mailer in the app sends through the provider above.
          - Two kinds of mail are kept apart. TRANSACTIONAL is anything somebody
            is waiting for -- sign-in codes, receipts, password resets. BROADCAST
            is anything bulk. #{broadcast? ? "They go through different providers here, so a spam complaint about a newsletter cannot damage the reputation that delivers sign-in codes." : "One provider handles both here."}
          - Put bulk mail on the broadcast stream by setting
            `headers["X-Sparrow-Stream"] = "broadcast"` in the mailer method,
            before the `mail` call. Anything without that header is
            transactional. There is no `stream:` option on `mail`.
          - `SparrowMail.deliveries` collects messages in test and sandbox modes.

          Settings live in Rails encrypted credentials under `sparrow_mail:`.
          Read them with `bin/rails credentials:edit`. Do not hardcode an API key
          and do not add a second mail configuration -- ActionMailer's own
          smtp_settings are not used when this delivery method is set.

          When writing code for this app: write plain ActionMailer mailers. Do
          not reach for a provider's SDK directly, and do not set
          `delivery_method` per mailer.
        BRIEF
      end

      private

      # Every stream stored, other than the transactional one, is a broadcast
      # stream by construction -- the panel writes exactly one, and a host that
      # declared others in an initializer is past needing this paragraph. That
      # includes one stored under the panel's old name for it, which is why
      # this looks for any other Hash rather than for `broadcast` by name.
      def broadcast_stream
        @broadcast_stream ||= stored.keys.map(&:to_sym).find do |name|
          next false if name == :transactional
          next false if SparrowMail::CREDENTIALS_SCALARS.include?(name)

          stored[name].is_a?(Hash)
        end
      end

      def broadcast? = !broadcast_stream.nil?

      def provider_for(stream)
        adapter = stored.dig(stream, :adapter)
        return "not set" if adapter.blank?

        "#{registry.display_name_for(adapter)}#{credentials_note(stream)}"
      end

      # Whether the provider has anything that reads like a key, by name only.
      def credentials_note(stream)
        settings = stored[stream] || {}
        return "" if settings.keys.any? { |name| ::SparrowUi::Console::Settings.secret?(name) }

        " (NO credentials set -- it will fail to authenticate on the first send)"
      end
    end
  end
end
