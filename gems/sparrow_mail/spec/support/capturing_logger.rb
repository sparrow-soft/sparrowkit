# frozen_string_literal: true

# Captures everything written to it, in every form a Logger accepts, so a spec
# can assert on what did and did not reach the log. Blocks are evaluated
# immediately: a lazily-evaluated block that would have leaked a body still
# counts as a leak.
class CapturingLogger
  attr_reader :entries

  def initialize
    @entries = []
  end

  %i[debug info warn error fatal unknown].each do |level|
    define_method(level) do |message = nil, &block|
      @entries << [level, (block ? block.call : message).to_s]
      true
    end
  end

  def add(_severity, message = nil, progname = nil, &block)
    @entries << [:add, (block ? block.call : (message || progname)).to_s]
    true
  end

  def lines
    entries.map(&:last)
  end

  def text
    lines.join("\n")
  end
end

RSpec::Matchers.define :have_logged do |expected|
  match { |logger| logger.text.include?(expected) }

  failure_message do |logger|
    "expected a log line containing #{expected.inspect}, got:\n#{logger.text}"
  end

  failure_message_when_negated do |logger|
    "expected NO log line to contain #{expected.inspect}, but got:\n#{logger.text}"
  end
end
