# frozen_string_literal: true

require "rails_helper"

# The control panel, end to end: sparrow_ui's mount, this gem's console engine,
# the real Settings, and real Rails encrypted credentials on disk.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
PAY_PANEL = "/sparrowkit/pay"

RSpec.describe "the payments control panel", type: :request do
  # sparrow_ui's gate refuses anything that is not local development, and it
  # runs as engine middleware ahead of this engine's routes. The suite runs in
  # the test environment, so development is the half that has to be stubbed;
  # the loopback half is satisfied by the integration session's REMOTE_ADDR.
  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
  end

  # Whichever processor Pay happens to list first, and whatever Pay reads for
  # it. NAMED NOWHERE IN THIS FILE, for the same reason the panel names none:
  # a spec pinned to one processor is a spec that has to be edited when Pay
  # ships another, and it would be quietly asserting the panel knows which.
  def a_processor
    SparrowPay::Console::Processors.names.find { |name| SparrowPay::Console::Processors.fields_for(name).any? }
  end

  def fields
    SparrowPay::Console::Processors.fields_for(a_processor)
  end

  def secret_field
    fields.find { |name| SparrowUi::Console::Settings.secret?(name) }
  end

  def save(overrides = {})
    patch PAY_PANEL, params: {processor: a_processor.to_s}.merge(overrides)
  end

  describe "the hub" do
    it "lists the panel and links to it" do
      get "/sparrowkit"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Payments")
      expect(response.body).to include(PAY_PANEL)
    end

    it "reports the module as not set up before a processor is chosen" do
      get "/sparrowkit"

      expect(response.body).to include("Not set up")
      expect(response.body).to include("nothing can be charged")
    end
  end

  describe "the page" do
    it "renders" do
      get PAY_PANEL

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Payments")
    end

    it "offers every processor Pay is willing to run" do
      get PAY_PANEL

      SparrowPay::Console::Processors.names.each do |name|
        expect(response.body).to include(%(value="#{name}"))
      end
    end

    it "asks for exactly the settings Pay reads for the chosen processor" do
      ConsoleCredentials.reset!({"sparrow_pay" => {"default_processor" => a_processor.to_s}})

      get PAY_PANEL

      fields.each { |name| expect(response.body).to include(%(name="#{name}")) }
    end

    it "asks for no processor's settings until one is chosen" do
      get PAY_PANEL

      fields.each { |name| expect(response.body).not_to include(%(name="#{name}")) }
    end

    it "says it cannot save when there is no master key" do
      ConsoleCredentials.without_key!

      get PAY_PANEL

      expect(response.body).to include("cannot save anything yet")
    ensure
      ConsoleCredentials.reset!
    end
  end

  describe "saving" do
    it "writes this gem's own settings under sparrow_pay:" do
      save

      expect(ConsoleCredentials.stored_pay).to include(
        default_processor: a_processor.to_s
      )
    end

    # Each top-level key is named after whoever reads it, and Pay is the reader
    it "writes the processor's keys where Pay reads them, not with our own" do
      save(secret_field => "sk_test_notarealkey")

      expect(ConsoleCredentials.stored(a_processor)[secret_field]).to eq("sk_test_notarealkey")
      expect(ConsoleCredentials.stored_pay).not_to have_key(secret_field)
    end

    it "does not erase a stored key when the form submits the empty box it must render" do
      save(secret_field => "sk_test_notarealkey")
      save(secret_field => "")

      expect(ConsoleCredentials.stored(a_processor)[secret_field]).to eq("sk_test_notarealkey")
    end

    it "never sends a stored key back to the browser" do
      save(secret_field => "sk_test_notarealkey")

      get PAY_PANEL

      expect(response.body).not_to include("sk_test_notarealkey")
    end

    it "refuses a processor Pay does not run, and saves nothing" do
      save(processor: "not_a_processor")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ConsoleCredentials.stored_pay).to be_empty
    end

    it "ignores a key that is not one Pay reads for this processor" do
      # This is the one panel that writes a key it did not choose the name of,
      # so a loop over raw params would let a hand-made request put anything at
      # the top of somebody's credentials file.
      save(smuggled_key: "should not be written")

      expect(ConsoleCredentials.stored(a_processor)).not_to have_key(:smuggled_key)
      expect(ConsoleCredentials.stored).not_to have_key(:smuggled_key)
    end
  end

  describe "the prompt the hub offers" do
    # It exists to be pasted into somebody else's chat window, which is the
    # single worst destination on this console for an API key. Asserted rather
    # than reviewed, because the guide is built by string interpolation over
    # the same settings the form writes, and one careless `#{stored}` would do
    # it.
    it "never contains a stored key" do
      save(**fields.to_h { |name| [name, "sk_live_notarealkey_#{name}"] })

      get "/sparrowkit"

      fields.each { |name| expect(response.body).not_to include("sk_live_notarealkey_#{name}") }
    end

    it "says what is configured, so an assistant is not guessing" do
      save(**fields.to_h { |name| [name, "value-for-#{name}"] })

      get "/sparrowkit"

      # The prompt has to name an API that exists. It used to name
      # `organization.billing.active?`, which was deleted in 0.1.0 -- and an
      # assistant reading the prompt wrote code against it for two releases.
      expect(response.body).to include("organization.payment_processor")
      expect(response.body).to include(SparrowPay::Console::Processors.label_for(a_processor))
    end

    it "says plainly when something is not set, rather than describing it as working" do
      get "/sparrowkit"

      expect(response.body).to include("NOT set")
    end
  end

  describe "what the hub then says" do
    it "asks for attention while the processor's keys are missing" do
      save

      get "/sparrowkit"

      expect(response.body).to include("Check this")
    end

    it "reports ready once the processor and its keys are set" do
      save(**fields.to_h { |name| [name, "value-for-#{name}"] })

      get "/sparrowkit"

      expect(response.body).to include("Ready")
      expect(response.body).to include("Charging through")
    end
  end
end
