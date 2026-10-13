# frozen_string_literal: true

require "rails_helper"

RSpec.describe SparrowAuth::TorExits do
  let(:list) { (1..150).map { |n| "198.51.100.#{n % 250}\n2001:db8::#{n.to_s(16)}" }.join("\n") }

  it "answers no until a list has been fetched" do
    expect(described_class.include?("198.51.100.1")).to be(false)
  end

  it "replaces the list and answers from it" do
    allow(described_class).to receive(:fetch).and_return(list)

    expect(described_class.refresh!).to be > 100
    expect(described_class.include?("198.51.100.1")).to be(true)
    expect(described_class.include?("192.0.2.1")).to be(false)
  end

  # Rails can print an IPv6 address in more than one form.
  it "matches an IPv6 exit however it is written" do
    allow(described_class).to receive(:fetch).and_return(list)
    described_class.refresh!

    expect(described_class.include?("2001:0db8:0000:0000:0000:0000:0000:0001")).to be(true)
  end

  it "keeps the old list when the download is too short to be real" do
    list_tor_exit("198.51.100.9")
    allow(described_class).to receive(:fetch).and_return("<html>maintenance</html>")

    expect { described_class.refresh! }.to raise_error(SparrowAuth::Error, /only 0 addresses/)
    expect(described_class.include?("198.51.100.9")).to be(true)
  end

  it "answers no for a blank or unparseable address, or a cache that will not answer" do
    list_tor_exit
    expect(described_class.include?(nil)).to be(false)
    expect(described_class.include?("not an address")).to be(false)

    allow(Rails.cache).to receive(:read).and_raise(Errno::ECONNREFUSED)
    expect(described_class.include?(BotProtectionHelpers::TOR_EXIT)).to be(false)
  end

  it "is refreshed by a job" do
    allow(described_class).to receive(:fetch).and_return(list)

    SparrowAuth::RefreshTorExitsJob.perform_now

    expect(described_class.include?("198.51.100.1")).to be(true)
  end
end
