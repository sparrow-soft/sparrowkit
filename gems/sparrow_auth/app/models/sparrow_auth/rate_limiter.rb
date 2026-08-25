# frozen_string_literal: true

module SparrowAuth
  # The budgets that stop an address or an address book being walked.
  #
  # Every budget is a (bucket, window, limit) triple, and a bucket is counted
  # only against its own budget. That independence is not a convention here; it
  # is the data model. In the application this was drawn from, the counters
  # shared a table and overlapping queries,
  # so verify attempts consumed the send budget and a venue full of people on
  # one IP locked each other out of their own accounts, silently.
  #
  # There are no exemptions, for any address, including the operator's own.
  # That application had two hardcoded ones. An exemption is a bypass that
  # outlives the
  # reason for it, is never revisited, and is the first thing worth attacking
  # once anyone learns it exists.
  module RateLimiter
    Budget = Struct.new(:bucket, :window, :limit) do
      def exceeded?(subject)
        AuthEvent
          .where(bucket: bucket, subject: subject)
          .where(AuthEvent.arel_table[:created_at].gt(window.ago))
          .limit(limit)
          .count >= limit
      end
    end

    SEND_PER_EMAIL_MINUTE = Budget.new("otp_send:email", 60.seconds, 1)
    SEND_PER_EMAIL_HOUR = Budget.new("otp_send:email", 1.hour, 5)
    SEND_PER_IP = Budget.new("otp_send:ip", 1.hour, 10)
    VERIFY_PER_IP = Budget.new("otp_verify:ip", 15.minutes, 10)

    # Password guessing.
    #
    # The sign-in method with the weakest secret had no limit at all while the strongest
    # had four, which is the wrong way round: a passkey cannot be guessed and a
    # password is a word somebody chose.
    #
    # Ten wrong passwords in a quarter of an hour is far more than anybody
    # mistyping their own, and far fewer than anybody working through a list.
    # The per-IP budget is looser because one office, one household or one cafe
    # is one address, and locking a building out of its own accounts is the
    # failure this engine has a whole comment about.
    LOGIN_PER_EMAIL = Budget.new("login:email", 15.minutes, 10)
    LOGIN_PER_IP = Budget.new("login:ip", 15.minutes, 30)

    # Telling the owner their password is being guessed is worth doing once,
    # not once per attempt: otherwise the notification is itself the attack.
    LOGIN_NOTICE_PER_EMAIL = Budget.new("login_notice:email", 1.hour, 1)

    BUDGETS = {
      "otp_send:email" => [SEND_PER_EMAIL_MINUTE, SEND_PER_EMAIL_HOUR],
      "otp_send:ip" => [SEND_PER_IP],
      "otp_verify:ip" => [VERIFY_PER_IP],
      "login:email" => [LOGIN_PER_EMAIL],
      "login:ip" => [LOGIN_PER_IP],
      "login_notice:email" => [LOGIN_NOTICE_PER_EMAIL]
    }.freeze

    class << self
      def allowed?(bucket:, subject:)
        return true if subject.blank?

        BUDGETS.fetch(bucket).none? { |budget| budget.exceeded?(subject) }
      end

      def record(bucket:, subject:)
        return if subject.blank?

        AuthEvent.create!(bucket: bucket, subject: subject)
      end

      # Checks every budget for this action, and records the attempt only if it
      # was allowed. Recording a refused attempt would let someone at the cap
      # hold themselves there forever by continuing to try.
      def allow!(pairs)
        return false unless pairs.all? { |bucket, subject| allowed?(bucket: bucket, subject: subject) }

        pairs.each { |bucket, subject| record(bucket: bucket, subject: subject) }
        true
      end
    end
  end
end
