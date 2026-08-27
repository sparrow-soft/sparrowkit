# frozen_string_literal: true

require "action_mailer"
require "sparrow_mail/retryable_delivery_job"

# Mirrors delivery_method_spec.rb: a real ActionMailer class driven end to
# end through real ActiveJob execution, so this proves the retry behaviour
# rather than just the declared handler list.
class RetryableJobMailer < ActionMailer::Base
  self.delivery_job = SparrowMail::RetryableDeliveryJob

  def notify(to:)
    mail(from: "no-reply@example.com", to: to, subject: "This week") do |format|
      format.text { render plain: "news" }
    end
  end
end

RSpec.describe SparrowMail::RetryableDeliveryJob do
  before(:all) do
    ActionMailer::Base.add_delivery_method(:sparrow_mail, SparrowMail::DeliveryMethod)
  end

  before do
    ActionMailer::Base.delivery_method = :sparrow_mail
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    SparrowMail.configure { |config| config.adapter = :test }

    # Makes both an immediate retry_job re-enqueue (enqueue_at, since
    # retry_on always passes a wait) and the original deliver_later enqueue
    # run synchronously, so a persistent failure plays out fully inside the
    # example instead of sitting in a queue nothing here drains.
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true
    ActiveJob::Base.queue_adapter.perform_enqueued_at_jobs = true

    # Every retry logs at info by default; a persistent failure retried 5
    # times would otherwise flood the suite's output with expected noise.
    ActiveJob::Base.logger = Logger.new(File::NULL)
  end

  it "is an ActionMailer::MailDeliveryJob, so a mailer can point delivery_job at it directly" do
    expect(described_class.ancestors).to include(ActionMailer::MailDeliveryJob)
  end

  [SparrowMail::RateLimitError, SparrowMail::ProviderError, SparrowMail::NetworkError].each do |error_class|
    it "retries a persistent #{error_class} to exhaustion instead of raising on the first failure" do
      SparrowMail::Adapters::Test.fail_with(error_class, status_code: 500, payload: {})

      expect { RetryableJobMailer.notify(to: "a@example.org").deliver_later }
        .to raise_error(error_class)

      # attempts: 5 counts the original send, so 5 total calls reach the
      # adapter before the job finally gives up and re-raises.
      expect(SparrowMail::Adapters::Test.call_count).to eq(5)
    end
  end

  [SparrowMail::AuthenticationError, SparrowMail::InvalidRecipientError].each do |error_class|
    it "makes exactly one attempt for #{error_class}, since sending again cannot fix it" do
      SparrowMail::Adapters::Test.fail_with(error_class, status_code: 401, payload: {})

      expect { RetryableJobMailer.notify(to: "a@example.org").deliver_later }
        .to raise_error(error_class)

      expect(SparrowMail::Adapters::Test.call_count).to eq(1)
    end
  end

  it "makes exactly one attempt on success, same as the default delivery job" do
    RetryableJobMailer.notify(to: "a@example.org").deliver_later

    expect(SparrowMail::Adapters::Test.call_count).to eq(1)
  end
end
