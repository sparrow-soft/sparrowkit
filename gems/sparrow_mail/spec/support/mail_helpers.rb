# frozen_string_literal: true

# Builders for real Mail::Message objects. The specs deliberately construct
# genuine messages rather than doubles: adapters are judged on what they do with
# a real multipart message, attachments and all.
module MailHelpers
  # A distinctive string planted in every body the specs send. The conformance
  # suite asserts this never reaches a log line or an exception message, which
  # is how "never log message bodies" is proven rather than promised.
  SECRET_BODY = "OTP-CODE-483927-DO-NOT-LOG"

  def build_mail(
    from: "Sparrow <no-reply@example.com>",
    to: "Recipient <person@example.org>",
    subject: "Your sign-in code",
    text: "Here is your code: #{SECRET_BODY}",
    html: "<p>Here is your code: #{SECRET_BODY}</p>",
    cc: nil,
    bcc: nil,
    reply_to: nil,
    headers: {},
    attachments: {}
  )
    Mail.new.tap do |mail|
      mail.from = from
      mail.to = to
      mail.cc = cc if cc
      mail.bcc = bcc if bcc
      mail.reply_to = reply_to if reply_to
      mail.subject = subject

      headers.each { |name, value| mail.header[name.to_s] = value }
      attachments.each { |name, body| mail.attachments[name] = body }

      if text && html
        mail.text_part = Mail::Part.new { body text }
        mail.html_part = Mail::Part.new do
          content_type "text/html; charset=UTF-8"
          body html
        end
      elsif html
        mail.content_type "text/html; charset=UTF-8"
        mail.body = html
      else
        mail.body = text
      end
    end
  end

  def build_envelope(sandbox: false, **kwargs)
    SparrowMail::Envelope.from_mail(build_mail(**kwargs), sandbox: sandbox)
  end
end

RSpec.configure { |config| config.include MailHelpers }
