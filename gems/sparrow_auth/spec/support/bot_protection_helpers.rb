# frozen_string_literal: true

# Turning Turnstile on, answering for Cloudflare, and listing a Tor exit.
#
# Cloudflare is never called. Turnstile is switched on by setting both keys,
# and siteverify is replaced by a lambda that records what it was asked and
# returns a canned answer. The cache is a fresh memory store for each example,
# because the single-use claims and the Tor list both live in Rails.cache and
# must not leak between examples.
module BotProtectionHelpers
  TURNSTILE_TOKEN = "test-turnstile-token"
  TOR_EXIT = "203.0.113.7"

  def with_turnstile(answer: {})
    calls = []
    allow(SparrowAuth::Turnstile).to receive(:siteverify) do |params|
      calls << params
      answer.respond_to?(:call) ? answer.call(params) : answer
    end

    config = SparrowAuth.config
    site, secret = config.turnstile_site_key, config.turnstile_secret_key
    config.turnstile_site_key = "test-site-key"
    config.turnstile_secret_key = "test-secret-key"
    yield calls
  ensure
    config.turnstile_site_key = site
    config.turnstile_secret_key = secret
  end

  def turnstile_pass(action:, hostname: "www.example.com")
    {"success" => true, "action" => action, "hostname" => hostname, "error-codes" => []}
  end

  def list_tor_exit(ip = TOR_EXIT)
    Rails.cache.write(SparrowAuth::TorExits::CACHE_KEY, Set[ip])
  end
end

RSpec.configure do |config|
  config.include BotProtectionHelpers

  config.around do |example|
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = cache
  end
end
