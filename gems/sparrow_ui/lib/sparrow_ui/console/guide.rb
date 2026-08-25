# frozen_string_literal: true

module SparrowUi
  module Console
    # What a developer does next, once a module is configured.
    #
    # Two audiences, one source:
    #
    #   steps    for a person: shell commands and lines of code, in order
    #   brief    for a model: what this module is and what it gives you
    #
    # `brief` is the interesting half. A developer who would rather hand this to
    # an LLM than read it should be able to, and the thing that makes such a
    # prompt work is not prose about SparrowKit -- it is the CURRENT STATE of
    # this particular application. Which provider is configured, which routes
    # are mounted, which roles exist. A model given that writes code
    # that fits; a model given a generic description writes plausible code
    # against an API that does not exist.
    #
    # So a module builds its brief from its own settings, at render time, and it
    # is the module's job to be specific.
    #
    # NO SECRETS, EVER. The brief is written to be copied into somebody else's
    # chat window, which is the single worst destination for an API key on this
    # entire console. Modules say a key is set; they never say what it is. The
    # spec for this asserts it, and it is worth keeping asserted.
    Guide = Struct.new(:steps, :brief)

    class Guide
      def self.none = new(steps: [], brief: nil)

      # A module whose guide raised, said out loud.
      #
      # The alternative is `none`, which is what this used to be -- and a module
      # that cannot describe itself then looked exactly like a module with
      # nothing to describe. The guide is the text a developer pastes into an
      # assistant, so an empty one produces confidently wrong code rather than
      # an error anybody notices.
      def self.raising(error)
        new(steps: [], brief: "This module could not describe itself: #{error.class}.")
      end

      # Accepts the plain Hash a module can build without naming this class --
      # the same reason Status.from exists: every module is loaded in
      # production, and sparrow_ui is not.
      def self.from(value)
        return value if value.is_a?(Guide)
        return none unless value.is_a?(Hash)

        steps = value[:steps] || value["steps"]
        brief = value[:brief] || value["brief"]

        new(
          steps: Array(steps).map(&:to_s).reject(&:empty?),
          brief: brief&.to_s&.strip.presence
        )
      end

      def steps = self[:steps] || []

      def any? = steps.any? || brief.present?
    end
  end
end
