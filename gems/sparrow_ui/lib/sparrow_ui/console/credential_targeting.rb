# frozen_string_literal: true

require "active_support/concern"

module SparrowUi
  module Console
    # Resolves the selected encrypted credential store before a console action
    # can inspect settings or perform a side effect. The target is kept in the
    # browser session only after it passed Settings' server-owned allow-list.
    module CredentialTargeting
      extend ActiveSupport::Concern

      included do
        around_action :with_credential_target
        helper_method :credential_target
      end

      private

      attr_reader :credential_target

      def with_credential_target
        target = requested_credential_target
        return render_invalid_credential_target if target.nil?

        @credential_target = target
        Settings.with_target(target) { yield }
      end

      def requested_credential_target
        if params.key?(Settings::TARGET_PARAM)
          target = Settings.resolve_target(params[Settings::TARGET_PARAM])
          return nil if target.nil?

          session[Settings::TARGET_SESSION_KEY] = target.name
          target
        else
          Settings.resolve_target(session[Settings::TARGET_SESSION_KEY])
        end
      end

      def render_invalid_credential_target
        render plain: Settings.invalid_target_message, status: :unprocessable_entity
      end

      def refuse_production_execution
        return unless credential_target.production?

        render plain: "This action is unavailable for Production credentials.", status: :unprocessable_entity
      end
    end
  end
end
