# frozen_string_literal: true

# The behavioural proof that the two rules hold lives in the conformance suite,
# which runs every adapter against real (stubbed) provider responses. These
# specs are the structural backstop: they read the source and fail the build if
# anyone reintroduces the shapes the rules exist to forbid.
#
# A behavioural test proves the code we wrote is correct today. A structural
# test makes the next person's mistake loud. Both are cheap.
module InviolableRules
  LIB_ROOT = File.expand_path("../../lib", __dir__)

  # Every log line in this gem is produced by one private method in
  # Adapters::Base, which builds its output from Envelope#log_summary and
  # Result#to_h, neither of which can carry body content. Confining logging to a
  # single call site is what makes that guarantee checkable at all.
  LOGGING_CALL_SITES = ["sparrow_mail/adapters/base.rb"].freeze

  # Every knob a transport we build might expose for retrying, and the only
  # value each is allowed to hold. Capture-then-compare rather than a negative
  # lookahead: `/max_retries\s*=\s*(?!0)/` backtracks over the whitespace and
  # matches `max_retries = 0`, reporting a violation that is not there.
  RETRY_SETTINGS = /\b(max_retries|retry_limit|retry_count|retry_attempts)\b\s*[:=]\s*(\S+)/

  # `retry` used as a Ruby statement, which is the only form that re-runs a
  # begin block. Matching the bare word instead would flag every comment in the
  # gem that explains why there are no retries, which is most of them.
  RETRY_STATEMENT = /\Aretry\b(\s+(if|unless|while|until)\b|\s*(#.*)?\z)/
end

RSpec.describe "sparrow_mail's inviolable rules" do
  def ruby_sources
    Dir[File.join(InviolableRules::LIB_ROOT, "**", "*.rb")].sort
  end

  def relative(path)
    path.delete_prefix("#{InviolableRules::LIB_ROOT}/")
  end

  # Explicit, because Encoding.default_external follows the locale and a CI
  # runner without LANG set reads UTF-8 source as US-ASCII and blows up.
  def source(path)
    File.read(path, encoding: "UTF-8")
  end

  # Comment lines dropped. These checks are about what the code does; the gem's
  # comments discuss retrying at length precisely because it does not.
  def code_only(contents)
    contents.lines.reject { |line| line.strip.start_with?("#") }.join
  end

  describe "rule 1: message bodies are never logged" do
    it "invokes a logger from exactly one file" do
      offenders = ruby_sources.reject { |path| InviolableRules::LOGGING_CALL_SITES.include?(relative(path)) }
        .select { |path| source(path).match?(/logger\s*(&?\.|\.)\s*(debug|info|warn|error|fatal|add)\b/) }

      expect(offenders.map { |path| relative(path) }).to be_empty,
        "logging must stay confined to #{InviolableRules::LOGGING_CALL_SITES.join(", ")} so that " \
        "no adapter can log a body. Found logger calls in: " \
        "#{offenders.map { |path| relative(path) }.join(", ")}"
    end

    it "never passes an envelope or a mail object to the logger" do
      base = source(File.join(InviolableRules::LIB_ROOT, "sparrow_mail/adapters/base.rb"))
      logging_lines = base.lines.grep(/logger/)

      expect(logging_lines.join).not_to match(/logger.*\b(envelope|mail)\b(?!\.log_summary)/),
        "log lines must be built from log_summary, never from the envelope or mail itself"
    end
  end

  describe "rule 2: a send is never retried" do
    it "contains no retry statement anywhere in the library" do
      offenders = ruby_sources.flat_map { |path|
        source(path).lines.each_with_index.filter_map do |line, index|
          "#{relative(path)}:#{index + 1}" if line.strip.match?(InviolableRules::RETRY_STATEMENT)
        end
      }

      expect(offenders).to be_empty,
        "a `retry` in this gem re-sends a message. If a caller wants to try again " \
        "it must construct a new send, knowingly. Found at: #{offenders.join(", ")}"
    end

    it "actually detects a retry statement, so the check above cannot pass vacuously" do
      expect("  retry".strip).to match(InviolableRules::RETRY_STATEMENT)
      expect("retry if attempts < 3").to match(InviolableRules::RETRY_STATEMENT)
      expect("# explains why we never retry").not_to match(InviolableRules::RETRY_STATEMENT)
      expect('"a transport\'s own retry behaviour"').not_to match(InviolableRules::RETRY_STATEMENT)
    end

    it "never configures a transport to retry on our behalf" do
      offenders = ruby_sources.flat_map { |path|
        code_only(source(path)).scan(InviolableRules::RETRY_SETTINGS)
          .reject { |_setting, value| value.delete(",") == "0" }
          .map { |setting, value| "#{relative(path)}: #{setting} = #{value}" }
      }

      expect(offenders).to be_empty,
        "Net::HTTP and the AWS SDK both retry by default. Every transport this " \
        "gem builds must switch that off explicitly. Found: #{offenders.join("; ")}"
    end

    it "actually detects a retry setting, so the check above cannot pass vacuously" do
      expect("client.retry_limit = 3".scan(InviolableRules::RETRY_SETTINGS)).to eq([["retry_limit", "3"]])
      expect("http.max_retries = 0".scan(InviolableRules::RETRY_SETTINGS)).to eq([["max_retries", "0"]])
    end

    it "switches off Net::HTTP's built-in retry, which is on by default" do
      http = source(File.join(InviolableRules::LIB_ROOT, "sparrow_mail/transport/http.rb"))

      expect(http).to include("max_retries = 0")
    end
  end
end
