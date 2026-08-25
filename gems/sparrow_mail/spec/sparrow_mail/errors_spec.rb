# frozen_string_literal: true

RSpec.describe "SparrowMail's error taxonomy" do
  # Five categories, fixed. An application switching providers must be able to
  # write one rescue and have it keep meaning the same thing, which is only true
  # if the vocabulary is the gem's rather than each provider's.
  describe "categories" do
    {
      SparrowMail::AuthenticationError => :auth,
      SparrowMail::InvalidRecipientError => :invalid_recipient,
      SparrowMail::RateLimitError => :rate_limited,
      SparrowMail::ProviderError => :provider_down,
      SparrowMail::NetworkError => :provider_down,
      SparrowMail::UnknownError => :unknown
    }.each do |error_class, category|
      it "puts #{error_class.name.split("::").last} in the #{category} category" do
        expect(error_class.category).to eq(category)
        expect(error_class.new(adapter: :test).category).to eq(category)
      end
    end

    it "uses exactly the five categories and no more" do
      expect(SparrowMail::DeliveryError::CATEGORIES)
        .to eq(%i[auth invalid_recipient rate_limited provider_down unknown])
    end

    it "gives every delivery error a category from that list" do
      [
        SparrowMail::AuthenticationError,
        SparrowMail::InvalidRecipientError,
        SparrowMail::RateLimitError,
        SparrowMail::ProviderError,
        SparrowMail::NetworkError,
        SparrowMail::UnknownError
      ].each do |error_class|
        expect(SparrowMail::DeliveryError::CATEGORIES).to include(error_class.category)
      end
    end
  end

  describe SparrowMail::DeliveryError do
    subject(:error) do
      described_class.new(
        adapter: :postmark,
        status_code: 422,
        provider_code: 406,
        provider_message: "Inactive recipient",
        recipients: 2
      )
    end

    it "builds a message from its structured fields when given none" do
      expect(error.message).to include("postmark")
      expect(error.message).to include("422")
      expect(error.message).to include("406")
      expect(error.message).to include("Inactive recipient")
    end

    it "keeps an explicit message when given one" do
      expect(described_class.new("boom", adapter: :test).message).to eq("boom")
    end

    it "exposes a log-safe hash including the category" do
      expect(error.to_h).to include(
        adapter: :postmark,
        status_code: 422,
        provider_code: 406,
        recipients: 2
      )
    end

    # The base class is what an adapter raises when it genuinely cannot tell
    # what went wrong, so unknown is the honest default rather than a guess at
    # provider-down.
    it "defaults to the unknown category" do
      expect(described_class.category).to eq(:unknown)
      expect(error.to_h[:category]).to eq(:unknown)
    end

    it "omits fields that were never set rather than reporting them as nil" do
      expect(described_class.new(adapter: :test).to_h.keys)
        .to contain_exactly(:error, :category, :adapter)
    end

    # Exposing a retry hint would invite exactly the behaviour the gem exists to
    # prevent. An application deciding to send again must know it is making a new
    # send, not completing an old one.
    it "offers no retryable? hint" do
      expect(error).not_to respond_to(:retryable?)
    end

    it "descends from SparrowMail::Error so one rescue covers the gem" do
      expect(error).to be_a(SparrowMail::Error)
    end
  end

  describe SparrowMail::ConfigurationError do
    it "is not a delivery error, because it is a caller bug rather than a failure to send" do
      expect(SparrowMail::ConfigurationError.new("nope")).not_to be_a(SparrowMail::DeliveryError)
    end

    it "is still a SparrowMail::Error" do
      expect(SparrowMail::ConfigurationError.new("nope")).to be_a(SparrowMail::Error)
    end
  end
end
