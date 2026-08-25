# frozen_string_literal: true

# sparrow_auth refuses to send with no sender rather than guessing one, so a
# host has to say. This dummy needs it only because its specs create accounts,
# which sends a verification message.
SparrowAuth.configure do |config|
  config.mail_from = "Billing Demo <no-reply@example.test>"
end

SparrowMail.configure do |config|
  config.adapter = :test
  config.default_from = "Billing Demo <no-reply@example.test>"
end
