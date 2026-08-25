# frozen_string_literal: true

module SparrowAuth
  # A provider account somebody connected to theirs, as the rest of the
  # application sees it. Rodauth writes these rows during the ceremony; this is
  # for showing them and taking them away.
  class Identity < ApplicationRecord
    self.table_name = "sparrow_auth_account_identities"

    belongs_to :account, class_name: "SparrowAuth::Account", inverse_of: :identities

    scope :oldest_first, -> { order(:created_at) }

    def display_name
      [provider.to_s.humanize, email.presence].compact.join(" · ")
    end

    # The uid is the provider's identifier for a person and is not ours to
    # print. Nothing here needs it, and a log line carrying it links a person
    # across every system that ever saw it.
    def inspect
      "#<SparrowAuth::Identity account_id=#{account_id} provider=#{provider.inspect}>"
    end
    alias_method :to_s, :inspect
  end
end
