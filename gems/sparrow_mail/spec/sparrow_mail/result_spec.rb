# frozen_string_literal: true

RSpec.describe SparrowMail::Result do
  subject(:result) do
    described_class.new(adapter: :postmark, message_id: "abc-123", recipients: 2)
  end

  it "carries the adapter, provider message id and recipient count" do
    expect(result.adapter).to eq(:postmark)
    expect(result.message_id).to eq("abc-123")
    expect(result.recipients).to eq(2)
  end

  it "counts as delivered by default" do
    expect(result).to be_delivered
    expect(result).not_to be_sandbox
  end

  it "is not delivered when it was withheld in sandbox mode" do
    withheld = described_class.new(adapter: :postmark, sandbox: true, delivered: false)

    expect(withheld).to be_sandbox
    expect(withheld).not_to be_delivered
  end

  it "can be stamped as sandboxed after the fact, which is how the core marks provider sandbox sends" do
    stamped = result.with(sandbox: true)

    expect(stamped).to be_sandbox
    expect(stamped.message_id).to eq("abc-123")
    expect(result).not_to be_sandbox, "with() must not mutate the original"
  end

  it "can be stamped with a duration" do
    expect(result.with(duration_ms: 42).duration_ms).to eq(42)
  end

  it "exposes a log-safe hash" do
    expect(result.with(duration_ms: 7).to_h).to eq(
      adapter: :postmark,
      message_id: "abc-123",
      recipients: 2,
      duration_ms: 7,
      stream: nil,
      sandbox: false,
      delivered: true
    )
  end

  it "has no way to carry a message body" do
    expect(result).not_to respond_to(:text_body)
    expect(result).not_to respond_to(:html_body)
    expect(result).not_to respond_to(:body)
    expect(result).not_to respond_to(:raw_response)
  end

  describe "carrying a failure" do
    let(:failure) do
      SparrowMail::RateLimitError.new(adapter: :postmark, status_code: 429, recipients: 2)
    end

    subject(:failed) { described_class.failed(failure, recipients: 2) }

    it "reports success when there is no error" do
      expect(result).to be_success
      expect(result).not_to be_failure
      expect(result.error).to be_nil
    end

    it "reports failure when there is one" do
      expect(failed).to be_failure
      expect(failed).not_to be_success
    end

    it "carries the structured error" do
      expect(failed.error).to be(failure)
    end

    it "takes the adapter from the error, so a caller never has to correlate them" do
      expect(failed.adapter).to eq(:postmark)
    end

    it "exposes the error's category directly, which is what a caller branches on" do
      expect(failed.category).to eq(:rate_limited)
      expect(result.category).to be_nil
    end

    it "was not delivered" do
      expect(failed).not_to be_delivered
    end

    it "includes the error in its log-safe hash" do
      expect(failed.to_h[:error]).to include(category: :rate_limited, status_code: 429)
    end

    # A sandbox send is a success even though nothing was delivered. Conflating
    # the two would make every staging run look like a failure.
    it "counts a withheld sandbox send as a success" do
      withheld = described_class.new(adapter: :postmark, sandbox: true, delivered: false)

      expect(withheld).to be_success
      expect(withheld).not_to be_delivered
    end

    it "keeps the body out of inspect even when it carries an error" do
      leaky = SparrowMail::ProviderError.new("rejected: SECRET-CODE-1", adapter: :test)

      expect(described_class.failed(leaky).inspect).to include("ProviderError")
    end
  end
end
