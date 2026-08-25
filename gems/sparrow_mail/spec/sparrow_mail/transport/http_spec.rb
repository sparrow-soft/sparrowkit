# frozen_string_literal: true

RSpec.describe SparrowMail::Transport::Http do
  subject(:http) { described_class.new(base_url: "https://api.example.com/") }

  # Captures the Net::HTTP instance the transport builds, so the specs can
  # assert on how it was configured rather than only on what it sent. This is
  # the one place worth reaching through the abstraction: whether retries are
  # off is a property of the client object, invisible in the request.
  def capture_client
    captured = nil
    allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
      captured = original.call(*args)
    end
    yield
    captured
  end

  describe "the never-retry rule" do
    # Net::HTTP's max_retries defaults to 1: it silently resends after a
    # connection reset. For a POST to a send endpoint that is a duplicate
    # message, so it is switched off on every client this class builds.
    it "switches off Net::HTTP's built-in retry" do
      WebMock.stub_request(:post, "https://api.example.com/send").to_return(status: 200)

      client = capture_client { http.post_json("send", {}) }

      expect(client.max_retries).to eq(0)
    end

    it "leaves no other retry knob turned on" do
      WebMock.stub_request(:post, "https://api.example.com/send").to_return(status: 200)

      client = capture_client { http.post_json("send", {}) }

      expect(client.max_retries).to be_zero
    end
  end

  describe "timeouts" do
    it "applies the defaults" do
      WebMock.stub_request(:post, "https://api.example.com/send").to_return(status: 200)

      client = capture_client { http.post_json("send", {}) }

      expect(client.open_timeout).to eq(described_class::DEFAULT_OPEN_TIMEOUT)
      expect(client.read_timeout).to eq(described_class::DEFAULT_READ_TIMEOUT)
    end

    it "applies configured timeouts" do
      transport = described_class.new(
        base_url: "https://api.example.com/",
        open_timeout: 2,
        read_timeout: 3
      )
      WebMock.stub_request(:post, "https://api.example.com/send").to_return(status: 200)

      client = capture_client { transport.post_json("send", {}) }

      expect(client.open_timeout).to eq(2)
      expect(client.read_timeout).to eq(3)
    end
  end

  describe "#post_json" do
    before { WebMock.stub_request(:post, "https://api.example.com/send").to_return(status: 200) }

    it "sends the payload as JSON" do
      http.post_json("send", {"a" => 1})

      expect(WebMock).to have_requested(:post, "https://api.example.com/send")
        .with(body: '{"a":1}', headers: {"Content-Type" => "application/json"})
    end

    it "sends the headers the transport was built with" do
      transport = described_class.new(
        base_url: "https://api.example.com/",
        headers: {"Authorization" => "Bearer k"}
      )

      transport.post_json("send", {})

      expect(WebMock).to have_requested(:post, "https://api.example.com/send")
        .with(headers: {"Authorization" => "Bearer k"})
    end

    it "lets per-request headers override the defaults" do
      transport = described_class.new(
        base_url: "https://api.example.com/",
        headers: {"X-Token" => "default"}
      )

      transport.post_json("send", {}, headers: {"X-Token" => "override"})

      expect(WebMock).to have_requested(:post, "https://api.example.com/send")
        .with(headers: {"X-Token" => "override"})
    end

    it "resolves the path against the base url" do
      WebMock.stub_request(:post, "https://api.example.com/v3/deep/send").to_return(status: 200)

      described_class.new(base_url: "https://api.example.com/v3/deep/").post_json("send", {})

      expect(WebMock).to have_requested(:post, "https://api.example.com/v3/deep/send")
    end
  end

  describe "#post_multipart" do
    before { WebMock.stub_request(:post, "https://api.example.com/send").to_return(status: 200) }

    it "declares a boundary in the content type and uses it in the body" do
      http.post_multipart("send", {"field" => "value"})

      request = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first
      boundary = request.headers["Content-Type"][/boundary=(\S+)/, 1]

      expect(boundary).not_to be_nil
      expect(request.body).to include("--#{boundary}")
      expect(request.body).to end_with("--#{boundary}--\r\n")
    end
  end

  describe SparrowMail::Transport::Http::Response do
    it "treats 2xx as success" do
      expect(described_class.new(200, {}, "")).to be_success
      expect(described_class.new(202, {}, "")).to be_success
      expect(described_class.new(299, {}, "")).to be_success
    end

    it "treats anything else as failure" do
      expect(described_class.new(199, {}, "")).not_to be_success
      expect(described_class.new(300, {}, "")).not_to be_success
      expect(described_class.new(500, {}, "")).not_to be_success
    end

    it "parses a JSON body" do
      expect(described_class.new(200, {}, '{"a":1}').json).to eq("a" => 1)
    end

    it "returns nil rather than raising on a body that is not JSON" do
      expect(described_class.new(500, {}, "<html>Gateway Timeout</html>").json).to be_nil
    end

    it "returns nil for an empty body" do
      expect(described_class.new(202, {}, "").json).to be_nil
      expect(described_class.new(202, {}, nil).json).to be_nil
    end

    it "falls back to the raw body when the payload is not JSON" do
      expect(described_class.new(500, {}, "Service Unavailable").payload).to eq("Service Unavailable")
    end

    it "reads headers case-insensitively, since Net::HTTP downcases them" do
      response = described_class.new(202, {"x-message-id" => "abc"}, "")

      expect(response.header("X-Message-Id")).to eq("abc")
    end

    # A provider's error body routinely quotes the message it rejected, so a
    # Response printed by an error reporter would otherwise leak a body.
    it "keeps the body out of inspect" do
      response = described_class.new(422, {}, "rejected: SECRET-SIGN-IN-CODE")

      expect(response.inspect).not_to include("SECRET-SIGN-IN-CODE")
      expect(response.inspect).to include("status=422")
    end

    it "keeps the body out of to_s as well" do
      expect(described_class.new(422, {}, "SECRET-SIGN-IN-CODE").to_s)
        .not_to include("SECRET-SIGN-IN-CODE")
    end
  end
end
