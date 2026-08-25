# frozen_string_literal: true

module SparrowAuth
  # An active session, as the rest of the application sees it.
  #
  # Rodauth owns these rows: it creates one on sign-in, touches it on each
  # request, and deletes it on sign-out. This is the view for showing somebody
  # what is signed in as them, and for ending any of it.
  class Session < ApplicationRecord
    self.table_name = "sparrow_auth_account_active_session_keys"
    self.primary_key = [:account_id, :session_id]

    belongs_to :account, class_name: "SparrowAuth::Account", inverse_of: :sessions

    scope :newest_first, -> { order(last_use: :desc) }

    # A browser string is not a device name, and pretending otherwise means
    # parsing an endlessly irregular format badly. What somebody actually needs
    # is enough to tell one row from another, so this shortens rather than
    # interprets.
    def display_name
      agent = user_agent.to_s.strip
      return "Unknown browser" if agent.empty?

      (agent.length > 72) ? "#{agent[0, 72]}…" : agent
    end

    # The stored id is an HMAC of the key held in the cookie, so it is not a
    # credential and appears in the page safely. It is still not printed.
    def inspect
      "#<SparrowAuth::Session account_id=#{account_id} last_use=#{last_use}>"
    end
    alias_method :to_s, :inspect
  end
end
