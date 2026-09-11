# frozen_string_literal: true

require "active_support/encrypted_configuration"

module SparrowUi
  module Console
    # Reads and writes a module's configuration in the host application's Rails
    # encrypted credentials.
    #
    # Credentials rather than a YAML file of our own: it is already encrypted,
    # already safe to commit, already the place a Rails developer looks for a
    # secret, and `bin/rails credentials:edit` remains the way to do this by
    # hand. Adding a second store would mean two answers to "where is my API
    # key" and one of them going stale.
    #
    # ONE TOP-LEVEL KEY PER GEM, named after the gem that reads it:
    #
    #   sparrow_auth:
    #     webauthn_rp_id: example.com
    #     otp_secret: ...
    #   sparrow_mail:
    #     default_from: Acme <hello@acme.test>
    #     transactional:
    #       adapter: postmark
    #       api_key: ...
    #   stripe:
    #     private_key: ...
    #
    # That is the whole format, and it is a format only in the sense that YAML
    # is. `Rails.application.credentials.sparrow_mail` reads it, `bin/rails
    # credentials:edit` edits it, and a developer who has never seen this
    # console can work out what they are looking at.
    #
    # These used to be nested under a `sparrowkit:` umbrella, which grouped them
    # tidily and cost more than it was worth. Pay reads `stripe:` from the top
    # level and always will, so an umbrella could never hold everything anyway
    # -- it just meant two conventions instead of one, and a rule to remember
    # about which settings lived where. Top level for everything, named after
    # its reader, is one sentence long.
    #
    # NOTHING HERE HANDS A SECRET BACK TO A VIEW. `for_display` is the only
    # method a panel should render, and it returns presence and last four
    # characters, never a value. The write path is one-way on purpose: a value
    # goes in, and the only way to see it again is `credentials:edit`.
    module Settings
      TARGET_PARAM = :credential_target
      TARGET_SESSION_KEY = :sparrow_ui_credential_target
      INVALID_TARGET_MESSAGE = "Choose a supported credential target."

      Target = Struct.new(:name, :label, :content_path, :key_path) do
        def production?
          name == "production"
        end
      end

      class Unavailable < StandardError; end

      # Each target supplies Rails' encrypted-configuration API with its own
      # fixed ciphertext and key-file paths. Rails still resolves
      # RAILS_MASTER_KEY before that explicit target key, as it does for every
      # encrypted configuration.
      class TargetConfiguration < ActiveSupport::EncryptedConfiguration
      end

      # A short-lived facade around one target. It creates a fresh encrypted
      # configuration for every operation so a development read can never be
      # reused for a production request, or vice versa.
      class Store
        def initialize(target)
          @target = target
        end

        def app_url
          read(CONSOLE_KEY)[:app_url].to_s
        end

        def app_name
          read(CONSOLE_KEY)[:app_name].to_s
        end

        def app_host
          uri = URI.parse(app_url)
          uri.host.presence
        rescue URI::InvalidURIError
          nil
        end

        def all
          decrypted_config
        rescue Unavailable
          {}
        end

        def read(gem_key)
          value = all[gem_key.to_sym]
          value.is_a?(Hash) ? value : {}
        end

        def for_display(gem_key)
          Settings.mask(read(gem_key))
        end

        def write(gem_key, attributes)
          write_many(gem_key => attributes).fetch(gem_key.to_sym)
        end

        def write_many(changes)
          encrypted = opened_configuration
          data = encrypted.config.deep_dup
          merged = changes.to_h.each_with_object({}) do |(gem_key, attributes), out|
            key = gem_key.to_sym
            out[key] = Settings.deep_merge(
              data[key].is_a?(Hash) ? data[key] : {},
              Settings.sanitize(attributes)
            )
            data[key] = out[key]
          end
          encrypted.write(Settings.deep_stringify(data).to_yaml)
          merged
        rescue Unavailable
          raise NotWritable, not_writable_reason
        rescue
          raise NotWritable, not_writable_reason
        end

        def move_and_write(gem_key, moves:, attributes:)
          encrypted = opened_configuration
          data = encrypted.config.deep_dup
          key = gem_key.to_sym
          tree = data[key].is_a?(Hash) ? data[key].dup : {}
          moved = false

          moves.each do |from, to|
            next unless tree.key?(from.to_sym)

            value = tree.delete(from.to_sym)
            tree[to.to_sym] = value unless tree.key?(to.to_sym)
            moved = true
          end

          sanitized_attributes = Settings.sanitize(attributes)
          return false unless moved || sanitized_attributes.present?

          data[key] = Settings.deep_merge(tree, sanitized_attributes)
          encrypted.write(Settings.deep_stringify(data).to_yaml)
          true
        rescue Unavailable
          raise NotWritable, not_writable_reason
        rescue
          raise NotWritable, not_writable_reason
        end

        def writable?
          decrypted_config
          true
        rescue Unavailable
          false
        end

        def not_writable_reason
          "#{@target.label} credentials are unavailable. Make that target available and reload."
        end

        private

        def decrypted_config
          opened_configuration.config
        rescue
          raise Unavailable
        end

        def opened_configuration
          raise Unavailable unless @target.content_path.file?

          configuration = TargetConfiguration.new(
            config_path: @target.content_path,
            key_path: @target.key_path,
            env_key: "RAILS_MASTER_KEY",
            raise_if_missing_key: false
          )
          raise Unavailable unless configuration.key?

          configuration
        end
      end

      TARGETS = {
        "development" => ["Development", "development.yml.enc", "development.key"].freeze,
        "production" => ["Production", "production.yml.enc", "production.key"].freeze
      }.freeze

      # A field whose name matches this is masked on the way out and never
      # rendered. Matching on the NAME rather than a per-module list means a
      # module that adds `stripe_secret_key` tomorrow is covered without
      # telling us about it -- the failure mode of a missed list is a secret on
      # screen, so the default has to be "treat it as one".
      #
      # `auth` is deliberately NOT a word here, and `auth_code|auth_token|
      # authorization` are.
      #
      # Bare `auth` was added to catch Paddle's `vendor_auth_code`, and it
      # matched `webauthn_rp_id`, `webauthn_rp_name` and `webauthn_origin` --
      # so the passkey domain, which is a public domain name sent to every
      # browser in every ceremony, came back from `for_display` as a mask and
      # rendered into the form as the literal text `{:secret=>true, :set=>true}`.
      # A settings page that cannot show you a setting is worse than one that
      # shows you a domain.
      #
      # sparrow_mail's copy of this rule had the bare word and sparrow_ui's did
      # not, and the drift was in sparrow_ui's favour. Worth remembering when
      # the next name is added: a word in this regex is matched anywhere inside
      # any key, and "anywhere inside any key" is a larger set than it reads.
      SECRET_NAME = /key|secret|token|password|credential|auth_code|auth_token|authorization|user_name/i

      # There was an UNCHANGED marker here -- twelve bullets, rendered as a
      # secret field's VALUE when one was stored, and dropped on the way back in
      # so that saving the page did not overwrite a real key with decoration.
      #
      # Gone because the decoration moved to the placeholder, which is never
      # submitted at all. The box now posts blank when it is left alone, and a
      # blank secret was already dropped by the rule in `sanitize` that has been
      # there from the start. One rule instead of two, and no sentinel value
      # that a developer could type by accident.
      # The console's own settings, as opposed to any module's.
      #
      # One key, holding what more than one panel needs to know. Today that is
      # the application's address, which sparrow_auth wants the host of and
      # sparrow_pay wants the whole of -- asked once on the hub rather than
      # typed into two panels, because two boxes for one fact is one typo away
      # from passkeys bound to a domain nobody visits.
      #
      # Panels READ this and default their own fields from it; nothing here
      # writes into a module's key behind its back, and nothing at runtime
      # reads it at all. That last part is the constraint that shapes the rest:
      # sparrow_ui is a development-group gem and is simply absent in
      # production, so a value only stored here would vanish on deploy. Each
      # module goes on keeping its own copy, under its own key, exactly as
      # before -- this only stops a developer having to type it twice.
      CONSOLE_KEY = :sparrowkit

      module_function

      def resolve_target(value)
        return nil unless value.is_a?(String)

        label, content_name, key_name = TARGETS[value]
        return nil if label.nil?

        Target.new(
          name: value,
          label: label,
          content_path: Rails.root.join("config/credentials", content_name),
          key_path: Rails.root.join("config/credentials", key_name)
        )
      end

      def invalid_target_message
        INVALID_TARGET_MESSAGE
      end

      def with_target(target)
        previous = Thread.current[thread_target_key]
        Thread.current[thread_target_key] = target
        yield
      ensure
        Thread.current[thread_target_key] = previous
      end

      def current_target
        Thread.current[thread_target_key]
      end

      def target
        current_target || raise(Unavailable, "credential target has not been selected")
      end

      def store
        Store.new(target)
      end

      # The application's address, as the hub last recorded it.
      def app_url
        store.app_url
      end

      # What the product is called. Shown to people rather than matched against
      # anything: the name in the passkey prompt their operating system draws,
      # and the name mail can come from.
      def app_name
        store.app_name
      end

      # ...and just its host, which is what a passkey binds to.
      #
      # nil rather than a guess for anything unparseable or missing a host, so
      # a caller defaults to nothing rather than to rubbish.
      def app_host
        store.app_host
      end

      def secret?(name)
        name.to_s.match?(SECRET_NAME)
      end

      # The whole decrypted tree, or {} when credentials are unreadable.
      def all
        store.all
      end

      # One gem's settings, by the top-level key that gem reads.
      def read(gem_key)
        store.read(gem_key)
      end

      # What a panel renders. Secrets collapse to presence plus the last four
      # characters; everything else passes through.
      #
      #   {default_from: "hello@acme.test",
      #    transactional: {adapter: "postmark",
      #                    api_key: {secret: true, set: true, hint: "1234"}}}
      #
      # THE RECURSION IS THE MASKING. A panel that configures two of something
      # -- two mail streams, two environments -- stores them as two subtrees,
      # and the flat version of this method saw `transactional:` as one value
      # under a name that is not a secret, so it handed the subtree to the view
      # whole, API key and all. Nesting quietly turned off the one rule this
      # module exists to enforce.
      def for_display(gem_key)
        store.for_display(gem_key)
      end

      def mask(tree)
        tree.each_with_object({}) do |(name, value), out|
          out[name] =
            if secret?(name)
              # Tested before the Hash check on purpose. A key called
              # `credentials:` holding a subtree is a secret whatever shape it
              # is in, and the safe answer to "secret, or section?" is
              # "secret".
              {secret: true, set: present?(value), hint: hint_for(value)}
            elsif value.is_a?(Hash)
              mask(value)
            else
              value
            end
        end
      end

      # Merges `attributes` into this module's settings and persists.
      #
      # A blank value for a SECRET is dropped rather than written, so a form
      # that renders an empty password field -- which it must, since the stored
      # value is never sent to the browser -- does not erase the stored key on
      # every save. A blank value for a non-secret is a deliberate clear and is
      # written through. Both hold at every depth: a secret is a secret whether
      # it sits at the top of a module's settings or inside a subtree.
      #
      # A `nil` REMOVES the key, subtree and all. Merging can only ever add,
      # and a panel needs to be able to say that a section has gone -- the mail
      # panel that stops sending broadcast mail through a second provider has to
      # take `broadcast:` back out, and leaving it behind would leave a stream
      # configured that nobody meant to keep.
      def write(gem_key, attributes)
        store.write(gem_key, attributes)
      end

      def write_many(changes)
        store.write_many(changes)
      end

      # Moves one subtree of a module's settings to another key, secrets and
      # all, and persists. Nothing when `from` is absent; when `to` is already
      # there, `from` is simply removed, because the current name is the one
      # that is being kept up to date and the old one is stale beside it.
      #
      # Exists because a panel cannot do this through `write`: the panel only
      # ever sees secrets masked, so writing what it has under the new key
      # would carry across everything except the API key. The value never
      # leaves this module.
      #
      # Returns true when the file changed.
      def move(gem_key, from:, to:)
        store.move_and_write(gem_key, moves: {from => to}, attributes: {})
      end

      def move_and_write(gem_key, moves:, attributes:)
        store.move_and_write(gem_key, moves: moves, attributes: attributes)
      end

      # Retained for callers that previously cleared Rails' default credentials
      # cache after a console save. Target stores are new per operation, so they
      # have no process-level decrypted tree to clear.
      def forget!
      end

      def writable?
        store.writable?
      end

      def not_writable_reason
        store.not_writable_reason
      end

      # -- mailboxes -------------------------------------------------------
      #
      # A sender is two things to type and two things to get wrong, and one
      # RFC 5322 value to store. Both panels that collect one need the same
      # pair of conversions, and they live here rather than in either of them
      # because the interesting half is the quoting rule -- two copies of that
      # would drift, and the drift is mail delivered to a recipient called
      # "Acme".

      # `Acme <hello@acme.test>` into [name, email]. A bare address has no name.
      #
      # Quotes come off here and go back on in compose_mailbox, so a name that
      # requires quoting survives a save-reload-save cycle without collecting
      # another pair each pass.
      def split_mailbox(value)
        value = value.to_s.strip
        return [nil, nil] if value.empty?

        match = value.match(/\A(?<name>.*?)\s*<(?<email>[^>]+)>\z/)
        return [nil, value] if match.nil?

        [match[:name].strip.delete_prefix('"').delete_suffix('"'), match[:email].strip]
      end

      # [name, email] back into one mailbox.
      #
      # A name alone is not a sender and is dropped. An address alone is a valid
      # mailbox and is written bare.
      def compose_mailbox(name, email)
        name = name.to_s.strip
        email = email.to_s.strip
        return "" if email.empty?
        return email if name.empty?

        # RFC 5322 specials. Left unquoted, `Acme, Inc <a@b>` is a
        # comma-separated list of two addresses and the mail goes to a
        # recipient called "Acme".
        name = %("#{name.delete('"')}") if name.match?(/[(),.:;<>@\[\]\\"]/)

        "#{name} <#{email}>"
      end

      # -- internals -------------------------------------------------------

      # Panels hand this plain Hashes, not ActionController::Parameters: what a
      # form sent is the panel's business to read and check, and this module
      # should never be the thing that decides an unvetted parameter is worth
      # storing.
      def sanitize(attributes)
        attributes.to_h.each_with_object({}) do |(name, value), out|
          key = name.to_sym

          case value
          when nil then out[key] = nil
          when Hash then out[key] = sanitize(value)
          else
            next if secret?(key) && !present?(value)

            out[key] = value.is_a?(String) ? value.strip : value
          end
        end
      end

      # Subtrees merge into subtrees rather than replacing them, so a panel can
      # save one section without restating the others, and `nil` deletes.
      #
      # A subtree with nothing stored beneath it merges into an empty one,
      # for the same reason: `nil` means "not this key", and a first save of a
      # section used to write it out as `access_key_id:` with nothing after
      # the colon. Harmless to the code that reads it back and untidy in a
      # file a developer opens to check what the panel did.
      #
      # `stored` is never mutated: it comes from Rails' memoised credentials
      # tree, and writing into it would leave the process holding a
      # configuration that is not on disk.
      def deep_merge(stored, attributes)
        attributes.each_with_object(stored.dup) do |(key, value), out|
          if value.nil?
            out.delete(key)
          elsif value.is_a?(Hash)
            out[key] = deep_merge(out[key].is_a?(Hash) ? out[key] : {}, value)
          else
            out[key] = value
          end
        end
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def hint_for(value)
        return nil unless present?(value)

        value.to_s.strip[-4..] || nil
      end

      def deep_stringify(object)
        case object
        when Hash then object.to_h { |k, v| [k.to_s, deep_stringify(v)] }
        when Array then object.map { |v| deep_stringify(v) }
        else object
        end
      end

      def thread_target_key
        :sparrow_ui_console_credential_target
      end

      # Raised when a panel tries to save and the application cannot decrypt or
      # rewrite its own credentials. Surfaced to the developer, never swallowed:
      # a save that silently does nothing is worse than an error.
      class NotWritable < StandardError; end
    end
  end
end
