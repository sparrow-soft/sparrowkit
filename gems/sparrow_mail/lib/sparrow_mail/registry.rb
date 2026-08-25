# frozen_string_literal: true

module SparrowMail
  # Maps adapter names to adapter classes.
  #
  # Built-in adapters are registered by file path and constant name rather than
  # by class, so requiring this gem does not load every adapter. That matters
  # for exactly one of them today — the Amazon SES adapter needs the AWS SDK,
  # and an application using Postmark should not pay for it — but the same
  # laziness keeps the door open for future adapters with heavy dependencies.
  class Registry
    Entry = Struct.new(:require_path, :constant_name, :klass, :display_name)

    def initialize
      @entries = {}
    end

    def register(name, klass)
      @entries[name.to_sym] = Entry.new(nil, nil, klass, nil)
      self
    end

    # `display_name` is a fallback and nothing more. The adapter class is where
    # a brand is declared -- see Adapters::Base.display_name -- and it is asked
    # first. This exists for the one case where it cannot be: an adapter whose
    # optional gem is absent never defines its class, so there is nothing to
    # ask, and a console listing it as `ses` rather than `Amazon SES` is the
    # visible cost.
    #
    # registry_spec asserts the two agree for every built-in, so the copy here
    # cannot quietly drift from the class it stands in for.
    def register_lazy(name, require_path, constant_name, display_name = nil)
      @entries[name.to_sym] = Entry.new(require_path, constant_name, nil, display_name)
      self
    end

    # What to call this adapter without loading it.
    #
    # The class when it is already loaded or loadable, the registered fallback
    # when it is not, and the key when nobody said anything at all.
    def display_name_for(name)
      entry = @entries[name.to_sym]
      return name.to_s if entry.nil?

      loaded =
        begin
          entry.klass || resolve(entry, name)
        rescue ConfigurationError
          nil
        end

      loaded&.display_name || entry.display_name || name.to_s
    end

    def delete(name)
      @entries.delete(name.to_sym)
    end

    # Registration order, deliberately not alphabetical.
    #
    # This is the order a person sees them in, and alphabetical is an ordering
    # that means nothing to the reader -- it put Mailgun first because of its
    # first letter. BUILT_IN_ADAPTERS decides for the adapters this gem ships;
    # anything an application registers itself lands after them, which is the
    # right place for it.
    #
    # The console renders this list as it comes. Sorting it there would be a
    # second opinion about provider names in the one file that must not hold
    # any.
    def names
      @entries.keys
    end

    def key?(name)
      @entries.key?(name.to_sym)
    end

    def fetch(name)
      entry = @entries[name.to_sym]

      if entry.nil?
        raise ConfigurationError,
          "unknown sparrow_mail adapter #{name.inspect}. " \
          "Available adapters: #{names.join(", ")}. " \
          "Register your own with SparrowMail.register_adapter(:name, MyAdapter)."
      end

      entry.klass ||= resolve(entry, name)
    end

    private

    def resolve(entry, name)
      require entry.require_path
      Object.const_get(entry.constant_name)
    rescue LoadError => e
      # The advice is appended only when the adapter did not already give it.
      # An adapter that knows it needs a particular gem raises a LoadError
      # saying so by name -- see adapters/ses.rb -- and blindly adding a second
      # "Add it to your Gemfile." produced the stutter a developer actually
      # read: "...Add `gem "aws-sdk-sesv2"` to your Gemfile.. Add it to your
      # Gemfile."
      advice = e.message.include?("Gemfile") ? nil : " Add it to your Gemfile."

      raise ConfigurationError,
        "the #{name} adapter needs a gem that is not installed: #{e.message}#{advice}"
    end
  end
end
