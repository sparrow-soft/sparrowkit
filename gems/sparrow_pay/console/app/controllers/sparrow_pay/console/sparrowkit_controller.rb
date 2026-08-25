# frozen_string_literal: true

module SparrowPay
  module Console
    # The one page sparrow_pay contributes to the developer console: which
    # processor charges the customer, its keys, and the handful of settings this
    # gem itself owns.
    #
    # It writes to TWO top-level keys, each named after whoever reads it:
    #
    #   sparrow_pay:   this gem's settings, applied by the engine at boot
    #   <processor>:   the processor's keys, which Pay reads itself
    #
    # The second is not ours to place. Pay looks its keys up there and has done
    # since long before this console; moving them would write a file Pay cannot
    # see, and the developer would be looking at a saved key that does nothing
    # -- a worse failure than no panel at all, because it looks like success.
    #
    # Nothing here names a processor, and the panel would work for one released
    # after this was written. See spec/sparrow_pay/processor_seam_spec.rb.
    #
    # No gate here. sparrow_ui's engine middleware refused anything that was not
    # local development before routing ran, and it covers every panel mounted
    # below it, including this one.
    class SparrowkitController < ActionController::Base
      # This engine's URL helpers, included by hand, and the line is load-bearing.
      #
      # Rails gives an isolated engine's controllers their route helpers through
      # the FIRST module in the class's ancestry that answers
      # `railtie_routes_url_helpers` -- see AbstractController::Railties::RoutesHelpers.
      # That module is SparrowPay, and SparrowPay::Engine claimed it first, so
      # without this every controller under this namespace resolves its paths
      # against the billing engine's route set and `sparrowkit_path` does not
      # exist there. The failure is at render time, on a page that otherwise
      # looks fine, which is a poor place to discover it.
      include SparrowPay::ConsoleEngine.routes.url_helpers

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

      MODULE_KEY = SparrowPay::CREDENTIALS_KEY

      # What a checkbox sends -- a hidden field plus a box, so the parameter is
      # always present and always one of these two. A checkbox alone sends
      # nothing when it is off, and "absent" and "off" would then be the same
      # request as "the client never rendered the control".
      ON = "1"
      OFF = "0"

      def show
        load_panel
        render :show
      end

      def update
        unless settings.writable?
          return refuse("Nothing was saved: #{settings.not_writable_reason}")
        end

        # A hand-made request can send a hash where the page sends a line of

        chosen = scalar(:processor)
        unless chosen.empty? || Processors.known?(chosen)
          return refuse("#{chosen.inspect} is not a processor Pay runs. " \
                        "It offers: #{Processors.names.join(", ")}.")
        end

        # The exact opposite of what this used to demand.
        #
        # It refused an absolute URL and required a leading slash, and that was
        # backwards: the value is handed to the processor untouched as the
        # address to send a customer back to. Nothing joins it to a host --

        settings.write(MODULE_KEY, own_attributes(chosen))
        settings.write(chosen.to_sym, processor_attributes(chosen)) unless chosen.empty?

        redirect_to root_path, notice: "Payment settings saved to your Rails credentials."
      end

      private

      def settings
        ::SparrowUi::Console::Settings
      end

      def absolute_url?(value)
        uri = URI.parse(value)

        uri.is_a?(URI::HTTP) && uri.host.present?
      rescue URI::InvalidURIError
        false
      end

      def load_panel
        @writable = settings.writable?
        @not_writable_reason = @writable ? nil : settings.not_writable_reason

        @processors = Processors.names
        # What the form should come back showing: whatever was just submitted
        # when a save was refused, and the stored configuration otherwise.
        chosen = (typed(:processor) || stored[:default_processor]).to_s
        @processor = (chosen.empty? || !Processors.known?(chosen)) ? nil : chosen.to_sym

        @fields = @processor ? fields_for_display(@processor) : []
        @client_gem_missing = @processor && @fields.empty?

        # Falls back to the address recorded on the hub rather than to
        # Configuration's default, which is "/" and cannot work: this value is
        # handed to the processor untouched as the URL to send a customer back
        # to, and a bare path is refused there.
        #
        @allow_fake = switch(:allow_test_processor, stored[:allow_test_processor])
      end

      # One row per credential Pay reads, carrying whether it is set and never
      # what it is set to. A key rendered on a page is a key in a screenshot, a
      # screen recording and a browser history, and a key that has been
      # photographed has to be rotated.
      def fields_for_display(processor)
        masked = settings.for_display(processor)

        Processors.fields_for(processor).map do |name|
          value = masked[name]

          {
            name: name,
            secret: settings.secret?(name),
            set: value.is_a?(Hash) ? value[:set] : !value.to_s.empty?,
            hint: value.is_a?(Hash) ? value[:hint] : nil,
            # A non-secret -- an environment, a store id -- is shown, because
            # the developer has to be able to see what it currently says.
            value: value.is_a?(Hash) ? nil : value.to_s
          }
        end
      end

      def own_attributes(chosen)
        {
          default_processor: chosen.presence,

          # Named `allow_test_processor` in the credentials rather than after
          # the processor it refers to, so that this gem's stored settings do
          # not carry a processor's name either.
          allow_test_processor: (params[:allow_test_processor].to_s == ON) || nil
        }
      end

      # Only the fields Pay actually reads for this processor, and only those
      # the form sent. Anything else in the request is ignored rather than
      # written: this is the one panel that writes outside the sparrowkit: tree,
      # so a loop over raw params here could put arbitrary keys at the top of
      # somebody's credentials file.
      def processor_attributes(chosen)
        Processors.fields_for(chosen.to_sym).each_with_object({}) do |name, out|
          next unless params.key?(name)

          # Blank reaches Settings.write, which drops blank SECRETS rather than
          # writing them: the form cannot show a stored key, so it has to submit
          # an empty box, and reading that as "erase it" would wipe the key on
          # every save. Rotating one is typing a new one. A blank non-secret is
          # a deliberate clear and is written through.
          out[name] = scalar(name)
        end
      end

      def stored
        @stored ||= settings.read(MODULE_KEY)
      end

      # The engine's own defaults, for a setting nothing has been stored for
      # yet. A fresh Configuration rather than SparrowPay.config, deliberately:
      # this page reads and writes ONE store, and prefilling from the live
      # configuration would put a value from the host's initializer into a box
      # whose save writes it somewhere else.
      def defaults
        @defaults ||= SparrowPay::Configuration.new
      end

      # Re-render rather than redirect, so the developer keeps what they typed.
      # flash.now, so it does not survive into the next page.
      def refuse(message)
        flash.now[:alert] = message
        load_panel
        render :show, status: 422
      end

      def switch(name, stored_value)
        submitted = params[name].to_s
        return submitted == ON unless submitted.empty?

        return stored_value[:set] if stored_value.is_a?(Hash)

        !!stored_value
      end

      # What was typed, or nil if this request did not carry the field at all.
      # Distinct from "typed nothing", which is a deliberate clear and must
      # survive a refused save.
      def typed(name)
        params.key?(name) ? scalar(name) : nil
      end

      # Form parameters arrive in whatever shape the request felt like. A
      # hand-made request that sends a hash where the page sends a string gets
      # an empty value and a 422, rather than `#<ActionController::Parameters ...>`
      # written into the credentials file.
      def scalar(name)
        value = params[name]
        value.is_a?(String) ? value.strip : ""
      end
    end
  end
end
