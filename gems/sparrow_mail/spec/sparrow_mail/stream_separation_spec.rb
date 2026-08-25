# frozen_string_literal: true

# Separation is REPORTED, not enforced.
#
# The reasoning for keeping bulk mail off a transactional sending reputation is
# unchanged and sound: complaints about a newsletter damage the deliverability
# of sign-in codes. What changed is the remedy. Raising here meant an
# application that named two streams on one provider would not boot -- so the
# gem whose job is "pick a provider and send" made the simple case harder than
# doing nothing, and the way out was to stop declaring the second stream, which
# is worse than declaring it badly.
#
# The control panel carries it as a note instead, where somebody can read it and
# decide. See SparrowMail::Console::Report#shared_identities.

# Declaring a stream is not the same as separating it. On a provider with no
# stream concept of its own, a stream that inherits the same credentials sends
# through the same identity, and the provider keeps one reputation for both.
# The label would be real and the protection would not, which is the worst
# combination: it reads as done.
#
# So the gem refuses to build a stream that cannot actually be separated, and
# says how to separate it.
RSpec.describe "stream separation" do
  def configure(adapter:, settings:, stream_options:)
    SparrowMail.configure do |config|
      config.adapter = adapter
      config.settings = settings
      config.stream :broadcast, **stream_options
    end
  end

  describe "providers with no stream concept of their own" do
    it "sends a stream that reuses the same credentials, rather than refusing to boot" do
      configure(adapter: :sendlayer, settings: {api_key: "one-key"}, stream_options: {settings: {}})

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "names the stream that is sharing, on the panel" do
      configure(adapter: :sendlayer, settings: {api_key: "one-key"}, stream_options: {settings: {}})

      expect(SparrowMail.streams_sharing_identity).to eq([:broadcast])
    end

    it "says how to fix it, on the panel" do
      configure(adapter: :sendlayer, settings: {api_key: "one-key"}, stream_options: {settings: {}})

      finding = SparrowMail::Console::Report.new.findings
        .find { |f| f[:title].to_s.include?("transactional sending identity") }

      expect(finding[:detail]).to include("shared_identity")
    end

    it "accepts a stream with its own credentials" do
      configure(
        adapter: :sendlayer,
        settings: {api_key: "transactional-key"},
        stream_options: {settings: {api_key: "bulk-key"}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "accepts a stream that goes through a different provider entirely" do
      configure(
        adapter: :sendlayer,
        settings: {api_key: "one-key"},
        stream_options: {adapter: :mailgun, settings: {api_key: "mg", domain: "news.example.com"}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    # Mailgun's identity is the key and the sending domain together, so a
    # separate subdomain is separation even on one account.
    it "counts a different Mailgun sending domain as separation" do
      configure(
        adapter: :mailgun,
        settings: {api_key: "one-key", domain: "mail.example.com"},
        stream_options: {settings: {domain: "news.example.com"}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "sends Mailgun when the key and the domain both match" do
      configure(
        adapter: :mailgun,
        settings: {api_key: "one-key", domain: "mail.example.com"},
        stream_options: {settings: {}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "counts a different SMTP relay as separation" do
      configure(
        adapter: :smtp,
        settings: {address: "smtp.example.com", user_name: "app"},
        stream_options: {settings: {address: "bulk-smtp.example.com"}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "sends SMTP through the same relay and login" do
      configure(
        adapter: :smtp,
        settings: {address: "smtp.example.com", user_name: "app"},
        stream_options: {settings: {}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end
  end

  describe "providers that model streams themselves" do
    # Postmark keeps a separate reputation per message stream on one server, so
    # one API key genuinely is enough.
    it "accepts Postmark on one key, because the stream id is part of the identity" do
      configure(adapter: :postmark, settings: {api_key: "one-key"}, stream_options: {settings: {}})

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "sends Postmark when both streams are pinned to the same stream id" do
      configure(
        adapter: :postmark,
        settings: {api_key: "one-key", message_stream: "outbound"},
        stream_options: {settings: {}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    # SES only separates if you give the stream its own configuration set.
    # Without one it is exactly as undifferentiated as SendLayer.
    it "sends SES with no configuration set to tell the streams apart" do
      configure(
        adapter: :ses,
        settings: {region: "us-east-1", access_key_id: "AKIA", secret_access_key: "s"},
        stream_options: {settings: {}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "accepts SES with its own configuration set" do
      configure(
        adapter: :ses,
        settings: {region: "us-east-1", access_key_id: "AKIA", secret_access_key: "s"},
        stream_options: {settings: {configuration_set_name: "bulk"}}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end
  end

  describe "opting out deliberately" do
    it "allows a shared identity when the application says so explicitly" do
      configure(
        adapter: :sendlayer,
        settings: {api_key: "one-key"},
        stream_options: {settings: {}, shared_identity: true}
      )

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end

    it "still routes and labels a shared-identity stream" do
      configure(
        adapter: :test,
        settings: {},
        stream_options: {settings: {}, shared_identity: true}
      )

      result = SparrowMail.deliver!(build_mail(headers: {"X-Sparrow-Stream" => "broadcast"}))

      expect(result.stream).to eq(:broadcast)
    end
  end

  describe "adapters with no reputation to protect" do
    it "never complains about the test adapter" do
      configure(adapter: :test, settings: {}, stream_options: {settings: {}})

      expect { SparrowMail.adapter_for(:broadcast) }.not_to raise_error
    end
  end

  describe "the transactional stream itself" do
    it "is never checked against anything" do
      SparrowMail.configure do |config|
        config.adapter = :sendlayer
        config.settings = {api_key: "one-key"}
      end

      expect { SparrowMail.adapter_for(:transactional) }.not_to raise_error
    end
  end
end
