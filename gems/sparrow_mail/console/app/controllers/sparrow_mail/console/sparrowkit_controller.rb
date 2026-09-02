# frozen_string_literal: true

module SparrowMail
  module Console
    # The one page sparrow_mail contributes to the developer console: pick a
    # provider, say which kinds of mail it handles, give it what it asks for,
    # name the sender.
    #
    # The panel configures sparrow_mail's OWN model of this and does not invent
    # a second one. SparrowMail::Configuration has exactly two moving parts
    # here:
    #
    #   * the default adapter and its settings, which carry the transactional
    #     stream -- Envelope::DEFAULT_STREAM, what mail with no stream header
    #     uses; and
    #   * `config.stream :broadcast, adapter: ..., settings: {...}`, a second
    #     provider with credentials of its own for bulk mail.
    #
    # So "one provider handles both" is not a broadcast stream that happens to
    # match. It is NO broadcast stream: nothing declared, nothing for
    # SparrowMail's verify_separation! to weigh up, nothing to keep in step.
    # That is genuinely the simple case, and it is stored as one.
    #
    # No gate here. sparrow_ui's engine middleware refused anything that was
    # not local development before routing ran, and it covers every panel
    # mounted below it, including this one.
    class SparrowkitController < ActionController::Base
      layout "sparrow_ui/console"

      # Asked for rather than inherited.
      #
      # ActionController::Base gets forgery protection from
      # `config.action_controller.default_protect_from_forgery`, which is on
      # from the 5.2 defaults -- so this page has been protected all along by a
      # line in somebody else's config file. An application that loads older
      # defaults, or sets it false for an API, silently turns it off here too;
      # and this controller writes credentials.yml.enc.
      #
      # :exception rather than :null_session. A console form that fails its
      # token should say so, not quietly save half of nothing.
      protect_from_forgery with: :exception

      MODULE_KEY = SparrowMail::CREDENTIALS_KEY

      # Named from the gem rather than restated. A rename there has to reach
      # this panel, and a copy would let it not.
      TRANSACTIONAL = SparrowMail::Envelope::DEFAULT_STREAM

      # The second stream's name is the one the rest of sparrow_mail already
      # used -- the README's header example, Postmark's built-in stream, the
      # conformance suite -- and not a word of this panel's own. It was, once,
      # and the library refused the README's header as an unknown stream on
      # every application the panel had configured. See
      # SparrowMail::CREDENTIALS_STREAM_ALIASES for how an old key is read.
      BROADCAST = :broadcast

      # What the first card's provider handles.
      #
      # "only transactional" and "only broadcast" say the same thing in
      # different words -- one provider each way round -- and both are offered
      # because a developer's starting point is whichever provider they already
      # have. What gets stored is the same either way: a transactional stream
      # and a broadcast stream. The panel keeps no record of which card they
      # were typed into, because sparrow_mail has no such notion and a second
      # answer to "which one is primary" could only ever contradict the first.
      BOTH = "both"
      HANDLES = [BOTH, TRANSACTIONAL.to_s, BROADCAST.to_s].freeze

      # Both cards are on the page whatever is chosen -- see the view -- and
      # the second is read only when the first provider handles one kind.
      CARDS = [:primary, :secondary].freeze

      def show
        load_panel
        render :show
      end

      def update
        unless settings.writable?
          return refuse("Nothing was saved: #{settings.not_writable_reason}")
        end

        unless HANDLES.include?(submitted_handles)
          return refuse("#{params[:handles].inspect} is not something a provider can handle. " \
                        "Choose one of: #{HANDLES.join(", ")}.")
        end

        chosen = {}

        streams.each do |stream, card|
          name = nested(card)[:adapter]
          choice = Adapters.find(name)

          if choice.nil?
            return refuse("#{name.to_s.inspect} is not a registered adapter. " \
                          "Choose one of: #{SparrowMail.registry.names.join(", ")}.")
          end

          unless choice.available?
            return refuse("The #{choice.name} adapter cannot be used here. #{choice.unavailable_reason}")
          end

          chosen[stream] = [card, choice]
        end

        # A stream stored under a name this panel no longer writes is moved
        # to its current name first, at the settings layer, because only that
        # layer holds the real key inside it -- this controller sees secrets
        # masked, and writing what it has under the new name would carry
        # across everything except the one value that matters. The write
        # below then merges into, or removes, the moved subtree as usual.
        SparrowMail::CREDENTIALS_STREAM_ALIASES.each do |old, current|
          settings.move(MODULE_KEY, from: old, to: current)
        end

        settings.write(MODULE_KEY, attributes_for(chosen))

        # Written to credentials, and now read back into THIS process.
        #
        # Without it the save is real and invisible: the file on disk is
        # correct, and the running application goes on using the configuration
        # it built at boot until somebody restarts it. The developer sees
        # "Mail settings saved to your Rails credentials", clicks back to the
        # hub, and the badge still says the module is not set up -- which is
        # how this was found.
        SparrowMail.reload_credentials!

        redirect_to root_path,
          notice: "Mail settings saved to your Rails credentials.",
          alert: separation_alert(chosen)
      end

      # Sends one real message through SparrowMail.deliver -- the same path the
      # application's own mail takes, because a test that exercises a different
      # path answers a different question. Failure comes back as a Result, and
      # each taxonomy category is turned into the sentence a person standing at
      # this page needs, with the provider's (already redacted) words after it.
      #
      # The guards run in setup order on purpose: no provider, no sender, no
      # recipient -- each refusal names the next step rather than the error.
      def clear_mailbox
        SparrowMail::Adapters::Preview.clear!

        redirect_to root_path, notice: "The mailbox is empty."
      end

      # One message per stream asked for. With one provider that is the
      # transactional stream and nothing else is offered; with two, the page
      # offers transactional, broadcast, or both -- and both is the default,
      # because two providers raise two questions and a test that answers
      # one of them leaves the newsletter path unproven until the first
      # newsletter.
      #
      # Each send is its own result. A broadcast that fails beside a
      # transactional that succeeds is reported as exactly that: one line in
      # the notice, one in the alert, each naming its stream and provider.
      def test_send
        configuration = SparrowMail.configuration

        if configuration.adapter.nil?
          return redirect_to root_path, alert: "Choose a provider and save it before sending a test."
        end

        if configuration.default_from.nil?
          return redirect_to root_path, alert: "Name a sender first — the test email has to come from somebody."
        end

        recipient = params[:recipient].to_s.strip
        if recipient.empty?
          return redirect_to root_path, alert: "Type the address the test should go to."
        end

        streams = requested_test_streams
        if streams.nil?
          return redirect_to root_path,
            alert: "#{params[:stream].inspect} is not a stream this application sends on. " \
                   "Configured: #{testable_streams.join(", ")}."
        end

        # The preview adapter would happily "succeed" here by writing a file,
        # and this is the one button on the console that must never do that.
        # Its entire job is answering "do my credentials work?", and Phase 4
        # already had to stop it answering yes having reached no network -- back
        # then because :test was offered in the dropdown. Selecting :preview by
        # default in development reopened exactly that hole from the other side.
        #
        # Asked of each stream, because a second provider is chosen per stream.
        previewing = streams.find { |stream| configuration.adapter_for_stream(stream) == Report::FALLBACK_ADAPTER }
        if previewing
          return redirect_to root_path,
            alert: "There is no provider to test yet — #{previewing} mail is being written to " \
                   "#{SparrowMail::Adapters::Preview::DIRECTORY} instead of sent. " \
                   "Choose one above, save it, and then send a test."
        end

        sent, refused = [], []

        streams.each do |stream|
          # A held button or a double-click must not spend sending reputation.
          # Rails.cache rather than the session, so two browser tabs share one
          # clock; one clock PER STREAM, so testing both in one press is one
          # press on each and a second press within the window holds both.
          # Dev-only page, dev-sized window.
          if Rails.cache.read(cooldown_key(stream))
            refused << "A #{stream} test just went out. Give it a moment before sending another."
            next
          end
          Rails.cache.write(cooldown_key(stream), true, expires_in: COOLDOWN)

          result = SparrowMail.deliver(test_message(configuration, recipient, stream))

          if result.success?
            held = configuration.sandbox? ? " Sandbox is on, so it was recorded rather than sent." : ""
            sent << "#{stream.to_s.capitalize} test handed to #{result.adapter} for #{recipient}.#{held}"
          else
            refused << "#{stream.to_s.capitalize}: #{refusal_sentence(result)} (#{result.error.message})"
          end
        rescue SparrowMail::Error => e
          # ConfigurationError is a SIBLING of DeliveryError, not a subclass,
          # so the adapter's own rescue does not catch it and it came out of
          # here as a Rails exception page -- from the panel whose entire job
          # is telling somebody their settings are wrong.
          #
          # A missing API key is the commonest way to arrive here, and it is a
          # thing to be told, not a stack trace. Per stream, so the other one
          # still gets its answer.
          refused << "#{stream.to_s.capitalize} did not send: #{e.message}"
        end

        if sent.any?
          sent << "If it does not arrive, the provider's dashboard has the delivery log."
        end

        redirect_to root_path,
          notice: sent.any? ? sent.join(" ") : nil,
          alert: refused.any? ? refused.join(" ") : nil
      end

      private

      COOLDOWN = 10.seconds
      COOLDOWN_KEY = "sparrow_mail:console:test_send"

      # What the form may ask for: one stream by name, or every stream this
      # application sends on.
      TEST_EVERY_STREAM = "both"

      def cooldown_key(stream)
        "#{COOLDOWN_KEY}:#{stream}"
      end

      # The streams a test can ride, in the order the page lists them: the
      # transactional stream, then the broadcast one when a second provider
      # is configured. Read from the live configuration rather than the
      # stored tree, because a send goes through the live configuration and
      # a test that answered for a different one would answer a different
      # question.
      def testable_streams
        SparrowMail.configuration.streams.select { |stream| [TRANSACTIONAL, BROADCAST].include?(stream) }
      end

      # The streams this request asked to test, or nil for a stream that is
      # not configured -- a forged form value, or a stale page from before a
      # second provider was taken back out.
      #
      # Nothing asked means every stream there is. With one provider that is
      # just transactional; with two it is both, which is the answer two
      # providers want.
      def requested_test_streams
        asked = params[:stream].to_s
        return testable_streams if asked.empty? || asked == TEST_EVERY_STREAM

        stream = asked.to_sym
        testable_streams.include?(stream) ? [stream] : nil
      end

      def test_message(configuration, recipient, stream)
        Mail.new.tap do |mail|
          mail.from = configuration.default_from
          mail.to = recipient
          mail.subject = "SparrowKit test email (#{stream})"
          # The header is what routes the message; the subject and body are
          # what tell two of them apart in one inbox.
          mail[SparrowMail::Envelope::STREAM_HEADER] = stream.to_s
          mail.body = <<~BODY
            This is a test email sent from the SparrowKit control panel at
            #{Time.current}, on the #{stream} stream, through
            #{configuration.adapter_for_stream(stream)}.

            If you are reading it, your #{stream} mail settings work.
          BODY
        end
      end

      # The taxonomy's category, said for a person standing at the settings
      # page. The error's own message follows in the caller, already through
      # the Redactor by the time it reaches a Result.
      def refusal_sentence(result)
        case result.category
        when :auth then "The provider refused the credentials — check the values saved above."
        when :invalid_recipient then "The provider refused that recipient address."
        when :rate_limited then "The provider is rate limiting this account right now."
        when :provider_down then "The provider could not be reached."
        else "The send failed."
        end
      end

      def settings
        ::SparrowUi::Console::Settings
      end

      # Masked: presence and last four characters for anything whose name reads
      # like a secret, at every depth. Nothing else in this controller reads
      # credentials, so there is no path by which a stored key reaches a view.
      def stored_tree
        @stored_tree ||= rename_old_streams(settings.for_display(MODULE_KEY))
      end

      # A stream stored under a name this panel no longer writes, shown under
      # the name it writes now -- so a second provider configured before the
      # rename is still on the page, still selected, still prefilled. The
      # stored key itself is moved on the next save; see update.
      def rename_old_streams(tree)
        SparrowMail::CREDENTIALS_STREAM_ALIASES.each_with_object(tree.dup) do |(old, current), out|
          next unless out.key?(old)

          out[current] = out.delete(old) unless out.key?(current)
          out.delete(old)
        end
      end

      # What is in the folder mail goes to while no provider is chosen.
      #
      # Only read when that is actually the state. An application sending
      # through Postmark has no mailbox here, and a stale list of whatever was
      # in tmp/ before they configured it would be worse than nothing.
      def mailbox
        return [] unless SparrowMail.configuration.adapter&.to_sym == Report::FALLBACK_ADAPTER

        SparrowMail::Adapters::Preview.recent(limit: MAILBOX_LIMIT)
      end

      MAILBOX_LIMIT = 10

      def load_panel
        @mailbox = mailbox
        @writable = settings.writable?
        @not_writable_reason = @writable ? nil : settings.not_writable_reason
        @choices = Adapters.all
        @handles = submitted_handles

        # What the form should come back showing: whatever was just submitted
        # when a save was refused, and the stored configuration otherwise.
        #
        # Two boxes over one stored value. `default_from` is a single RFC 5322
        # mailbox because that is what SparrowMail::Configuration takes and what
        # a consumer reads, so splitting it here rather than storing the halves
        # keeps one source of truth and nothing to hold in step.
        stored_name, stored_email = settings.split_mailbox(stored_tree[:default_from].to_s)
        @stored_sender_name = stored_name.to_s
        @stored_sender_email = stored_email.to_s
        # The product's name, inherited from the console's front page unless this
        # panel's stored mailbox names a sender of its own. A stored name IS the
        # override; there is no separate flag to disagree with it.
        @inherited_sender_name = settings.app_name.to_s
        @overriding_sender_name =
          if params.key?(:sender_name_override)
            params[:sender_name_override].to_s == "1"
          else
            @stored_sender_name.present?
          end
        @sender_name = params.key?(:sender_name) ? params[:sender_name].to_s : stored_name
        @effective_sender_name =
          @overriding_sender_name ? @sender_name.to_s : @inherited_sender_name
        @sender_email = params.key?(:sender_email) ? params[:sender_email].to_s : stored_email
        @selected = CARDS.to_h { |card| [card, selected_adapter(card)] }
        @test_streams = test_stream_choices
        @typed = CARDS.to_h { |card| [card, typed_settings(card)] }
        @stored_for = CARDS.to_h { |card| [card, stored_stream(card)] }
        @unregistered = CARDS.to_h { |card| [card, unregistered_adapter(card)] }

        @separation = separation_choice
      end

      # Re-render rather than redirect, so the developer keeps what they typed.
      # flash.now, so it does not survive into the next page.
      # What the test section offers: each stream a test can ride, with the
      # brand of the provider it rides through. Only worth a choice when there
      # are two, so the view checks the size.
      def test_stream_choices
        testable_streams.map do |stream|
          adapter = SparrowMail.configuration.adapter_for_stream(stream)
          [stream, adapter ? SparrowMail.registry.display_name_for(adapter) : nil]
        end
      end

      def refuse(message)
        flash.now[:alert] = message
        load_panel
        render :show, status: 422
      end

      # Which card configures which stream. Transactional is always one of
      # them: it is what mail with no stream header uses, and a configuration
      # without it cannot send at all.
      def streams
        case submitted_handles
        when BOTH then {TRANSACTIONAL => :primary}
        when BROADCAST.to_s then {BROADCAST => :primary, TRANSACTIONAL => :secondary}
        else {TRANSACTIONAL => :primary, BROADCAST => :secondary}
        end
      end

      # Submitted, or read back off what is stored: a broadcast stream means
      # two providers were configured, and its absence means one handles
      # everything.
      def submitted_handles
        submitted = params[:handles].to_s
        return submitted unless submitted.empty?

        stored_tree[BROADCAST].is_a?(Hash) ? TRANSACTIONAL.to_s : BOTH
      end

      def selected_adapter(card)
        submitted = nested(card)[:adapter].to_s
        return submitted unless submitted.empty?

        stream = streams.key(card)
        stream ? stored_tree.dig(stream, :adapter).to_s : ""
      end

      # The stored settings for this card's stream, and only when they were
      # stored under the provider the card now names -- so a Mailgun domain
      # never turns up prefilled beneath SendGrid.
      def stored_stream(card)
        stored = stored_tree[streams.key(card)]
        return {} unless stored.is_a?(Hash)
        return {} unless stored[:adapter].to_s == selected_adapter(card)

        stored
      end

      # An adapter the credentials name that the registry does not know. Worth
      # saying out loud: mail will not send until it is replaced, and nothing
      # else on the page would show it.
      def unregistered_adapter(card)
        stored = stored_tree[streams.key(card)]
        return nil unless stored.is_a?(Hash)

        name = stored[:adapter].to_s
        return nil if name.empty?
        return nil if @choices.any? { |choice| choice.name.to_s == name }

        name
      end

      # What each provider's boxes should show on a re-render.
      def typed_settings(card)
        @choices.to_h do |choice|
          fields = nested(card, :settings, choice.name.to_s)
          [choice.name.to_s, choice.fields.to_h { |field| [field.name, fields[field.name.to_s]] }]
        end
      end

      def overriding_sender_name?
        params[:sender_name_override].to_s == "1"
      end

      def attributes_for(chosen)
        # default_from is written alongside the streams: every adapter honours
        # it and none of them requires it, so it belongs to the panel rather
        # than to any one provider.
        # The NAME is left out unless somebody deliberately overrode it, so the
        # From line keeps following the product name rather than freezing a copy
        # of it. compose_mailbox writes a bare address when the name is blank,
        # which is exactly the shape SparrowMail::Configuration then puts the
        # product name in front of at send time.
        name = overriding_sender_name? ? params[:sender_name] : nil
        attributes = {default_from: settings.compose_mailbox(name, params[:sender_email])}

        chosen.each do |stream, (card, choice)|
          stored = stored_tree[stream]
          attributes[stream] = stream_attributes(card, choice, stored.is_a?(Hash) ? stored : {})
        end

        # One provider for everything means no broadcast stream at all. nil
        # takes the section back out rather than leaving a stream declared that
        # nobody meant to keep.
        attributes[BROADCAST] = nil unless chosen.key?(BROADCAST)

        attributes
      end

      # One card's provider and the settings that provider asks for.
      #
      # Every provider's fields are in the request. The page renders them all,
      # and with scripting off they are all visible, so the request carries
      # settings for providers nobody picked. Taking the fields FROM THE CHOSEN
      # ADAPTER, and only from there, is what keeps that from becoming a
      # credentials file full of half-filled providers.
      #
      # A blank value is passed through to Settings.write, which drops blank
      # SECRETS rather than writing them: the form cannot show a stored key, so
      # it has to submit an empty box, and reading that as "erase it" would
      # wipe the key on every save.
      #
      # UNLESS THE PROVIDER CHANGED. Then everything the old one left behind is
      # removed rather than merged in beneath the new one's name. That is
      # SparrowMail::Configuration#credentials_for's rule, for its reason: a
      # Mailgun key inherited by a Postmark configuration is a credential
      # authenticating as something else, and one that is confused quietly is
      # worse than one that is missing loudly.
      def stream_attributes(card, choice, stored)
        submitted = nested(card, :settings, choice.name.to_s)
        replacing = stored[:adapter].to_s != choice.name.to_s

        attributes = replacing ? stored.keys.to_h { |name| [name.to_sym, nil] } : {}
        attributes[:adapter] = choice.name.to_s

        choice.fields.each_with_object(attributes) do |field, result|
          value = submitted[field.name.to_s].to_s
          result[field.name] = (replacing && value.empty?) ? nil : value
        end
      end

      # The provider both kinds of mail would go through, when that is what has
      # been chosen and it is a provider with a reputation to lose. nil
      # otherwise, which is the ordinary case.
      def separation_choice
        return nil if @handles == BOTH

        name = @selected[:primary]
        return nil if name.empty? || name != @selected[:secondary]

        choice = Adapters.find(name)
        return nil unless choice&.available? && choice.reputation_bearing?

        choice
      end

      # Said on the way out as well as on the page, because a save redirects to
      # the hub, and a developer who never reopens this panel would otherwise
      # meet this as a ConfigurationError at boot instead.
      def separation_alert(chosen)
        choices = chosen.values.map { |(_card, choice)| choice }
        return nil unless choices.size > 1
        return nil unless choices.map(&:name).uniq.size == 1
        return nil unless choices.first.reputation_bearing?

        choice = choices.first
        "Both kinds of mail go through #{choice.name}, which tells one sender from another by " \
          "#{choice.identity_labels.to_sentence}. Unless the two carry different values there, the " \
          "provider cannot tell them apart and keeps one reputation for both. Bulk complaints would " \
          "then decide whether transactional mail is delivered, so SparrowMail refuses the send " \
          "rather than give you the label without the separation."
      end

      # Form parameters arrive in whatever shape the request felt like. Reading
      # the nested ones through here means a hand-made request that sends
      # `primary=x` where the page sends a hash gets the 422 the checks above
      # are for, rather than a NoMethodError from inside a dig.
      def nested(*keys)
        keys.reduce(params) { |level, key|
          break {} unless hashish?(level)

          level[key]
        }.then { |value| hashish?(value) ? value : {} }
      end

      def hashish?(value)
        value.is_a?(ActionController::Parameters) || value.is_a?(Hash)
      end
    end
  end
end
