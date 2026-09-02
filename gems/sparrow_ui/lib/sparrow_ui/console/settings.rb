# frozen_string_literal: true

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

      # The application's address, as the hub last recorded it.
      def app_url
        read(CONSOLE_KEY)[:app_url].to_s
      end

      # What the product is called. Shown to people rather than matched against
      # anything: the name in the passkey prompt their operating system draws,
      # and the name mail can come from.
      def app_name
        read(CONSOLE_KEY)[:app_name].to_s
      end

      # ...and just its host, which is what a passkey binds to.
      #
      # nil rather than a guess for anything unparseable or missing a host, so
      # a caller defaults to nothing rather than to rubbish.
      def app_host
        uri = URI.parse(app_url)
        uri.host.presence
      rescue URI::InvalidURIError
        nil
      end

      def secret?(name)
        name.to_s.match?(SECRET_NAME)
      end

      # The whole decrypted tree, or {} when credentials are unreadable.
      def all
        credentials&.config || {}
      rescue => e
        Rails.logger&.warn("[sparrow_ui] could not read credentials: #{e.class}")
        {}
      end

      # One gem's settings, by the top-level key that gem reads.
      def read(gem_key)
        value = all[gem_key.to_sym]

        value.is_a?(Hash) ? value : {}
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
        mask(read(gem_key))
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
      # panel that stops sending marketing through a second provider has to
      # take `marketing:` back out, and leaving it behind would leave a stream
      # configured that nobody meant to keep.
      def write(gem_key, attributes)
        raise NotWritable, not_writable_reason unless writable?

        merged = deep_merge(read(gem_key), sanitize(attributes))

        data = credentials.config.deep_dup
        data[gem_key.to_sym] = merged
        credentials.write(deep_stringify(data).to_yaml)
        forget!

        merged
      end

      # Drops Rails' memoised credentials object so the next read decrypts the
      # file we just wrote.
      #
      # Not housekeeping. ActiveSupport::EncryptedConfiguration memoises the
      # decrypted tree the first time anything reads it, and its #write does not
      # clear that -- while Rails memoises the configuration object itself on
      # the application, which lives for the whole process. Without this, a save
      # succeeds, the file on disk is correct, and every page for the rest of the
      # server's life keeps rendering what was there before: the panel says the
      # key is unset seconds after you set it, and a second save is computed by
      # merging into stale values and silently drops the first one.
      def forget!
        app = ::Rails.application
        return unless app.instance_variable_defined?(:@credentials)

        app.remove_instance_variable(:@credentials)
      end

      def writable?
        credentials.present? && credentials.key.present?
      rescue
        false
      end

      def not_writable_reason
        if credentials.nil?
          "this application has no credentials configured"
        else
          "no master key. Set RAILS_MASTER_KEY or create config/master.key, " \
          "then reload this page."
        end
      end

      def credentials
        return nil unless defined?(::Rails) && ::Rails.application

        ::Rails.application.credentials
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

      # Raised when a panel tries to save and the application cannot decrypt or
      # rewrite its own credentials. Surfaced to the developer, never swallowed:
      # a save that silently does nothing is worse than an error.
      class NotWritable < StandardError; end
    end
  end
end
