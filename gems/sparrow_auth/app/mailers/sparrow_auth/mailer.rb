# frozen_string_literal: true

module SparrowAuth
  # Auth email templates. The transport is sparrow_mail's problem; what lives
  # here is what the messages say.
  #
  # Two rules apply to every message below. Subjects are generic, because a
  # subject line is the part of an email most likely to be shown on a lock
  # screen, quoted in a notification, or logged by a mail gateway. And every
  # message rides the transactional stream, because auth mail must never share a
  # sending reputation with anything bulk: a newsletter's spam complaints should
  # not decide whether anyone can sign in.
  class Mailer < ActionMailer::Base
    default from: -> { SparrowAuth::Mailer.sender_address }

    # Named here rather than left to sparrow_mail's generic "message has no
    # sender", because the useful thing to say is which of two settings to
    # reach for, and the useful time to say it is the first time auth mail is
    # sent rather than after someone has read a stack trace through two gems.
    def self.sender_address
      SparrowAuth.config.mail_from ||
        SparrowMail.configuration.default_from ||
        raise(SparrowAuth::Error,
          "no from address for auth mail. Set SparrowAuth.config.mail_from, " \
          "or SparrowMail's config.default_from for every message the " \
          "application sends.")
    end

    def verify_account(email:, url:)
      @url = url
      transactional
      mail(to: email, subject: "Confirm your email address")
    end

    # Sent when someone tries to create an account with an address that already
    # has one. The attempt is not visible in the response, deliberately, so this
    # is how the news reaches the only person entitled to it.
    def account_exists(email:)
      transactional
      mail(to: email, subject: "Someone tried to create an account with your address")
    end

    # Sent when a code is requested for an address with no account. The screen
    # said the same thing it says to everyone; this is the only place the truth
    # is safe to state, because only the address's owner can read it.
    def no_account(email:)
      transactional
      mail(to: email, subject: "Someone asked to sign in with your address")
    end

    # Sent when an account's password has been guessed at often enough to be
    # throttled. The screen says what it says to every failed sign-in, so this
    # is the only place the news can safely go — and it is the news that matters
    # most, because it is how somebody learns to stop relying on a password.
    def password_attempts_throttled(email:, url:)
      @url = url
      transactional
      mail(to: email, subject: "Somebody is trying to sign in to your account")
    end

    # Sent when somebody signs in with a provider whose email matches an
    # existing account that has not connected that provider.
    #
    # The screen refuses without saying why, because saying why would answer
    # "does this address have an account here". This says why to the only person
    # entitled to know, and tells them the deliberate way to connect it.
    def provider_not_connected(email:, provider:, url:)
      @provider = provider
      @url = url
      transactional
      mail(to: email, subject: "Somebody signed in with #{provider} using your address")
    end

    # Sent when a code is requested for an account that never confirmed its
    # address. Without this the person is told their code is invalid and has no
    # way to discover why, which is the failure the uniform response creates.
    def verification_needed(email:, url:)
      @url = url
      transactional
      mail(to: email, subject: "Confirm your email address to sign in")
    end

    # The subject never contains the code.
    #
    # A subject line is the part of a message most likely to be shown on a lock
    # screen, read aloud by a notification, quoted in a reply, or written to a
    # mail gateway's logs. An application this was drawn from put the code in the
    # subject, which
    # is how a sign-in code ends up visible to anyone glancing at a phone.
    def sign_in_code(email:, code:)
      @code = code
      transactional
      mail(to: email, subject: "Your sign-in code")
    end

    # The other shape of the same message. No subject line difference worth
    # having: what is in it is a way into an account either way.
    def sign_in_link(email:, url:)
      @url = url
      transactional
      mail(to: email, subject: "Your sign-in link")
    end

    def invitation(email:, url:, invited_by: nil)
      @url = url
      @invited_by = invited_by
      transactional
      mail(to: email, subject: "You have been invited")
    end

    private

    def transactional
      headers[SparrowMail::Envelope::STREAM_HEADER] = SparrowAuth.config.mail_stream.to_s
      headers[SparrowMail::Envelope::TAGS_HEADER] = "auth"
    end
  end
end
