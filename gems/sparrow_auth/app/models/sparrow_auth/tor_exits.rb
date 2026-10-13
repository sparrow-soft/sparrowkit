# frozen_string_literal: true

require "ipaddr"
require "net/http"

module SparrowAuth
  # The Tor network's exit relays, refreshed from the Tor Project's own list by
  # SparrowAuth::RefreshTorExitsJob, so that a request for sign-in mail from one
  # of them can be answered without sending anything.
  #
  # Every request in the October 2026 sign-up spray came from a Tor exit, a
  # different one each visit, which is exactly what walks past a per-IP rate
  # limit. Somebody signing in over Tor is rare enough that the trade is worth
  # making, and they can still use a passkey: only mail is withheld.
  #
  # Refused in silence. SignIn.request answers a Tor exit exactly as it answers
  # everybody else, so the response tells a bot -- and anybody watching it --
  # nothing.
  #
  # Held in Rails.cache rather than the database: it is a few thousand
  # addresses replaced whole every hour, and losing it costs nothing but an
  # hour of the check being off. That is the failure mode throughout. No list,
  # an unreadable cache, an unparseable address -- all answer "not Tor",
  # because this decides whether a real person gets mail.
  #
  # Nothing is listed until the job has run once. Schedule it hourly.
  module TorExits
    SOURCE_URL = URI("https://check.torproject.org/torbulkexitlist")
    CACHE_KEY = "sparrow_auth/tor_exits/v1"

    # Long enough to ride out a day of failed refreshes, short enough that a
    # job that has stopped for good does not leave a stale list in force.
    TTL = 1.day

    # The list has held between one and two thousand addresses for years. A
    # response with far fewer is an error page or a truncated download, and
    # replacing a good list with it would quietly switch the check off.
    MINIMUM_SIZE = 100

    module_function

    def include?(ip)
      return false if ip.blank?

      Rails.cache.read(CACHE_KEY)&.include?(IPAddr.new(ip.to_s).to_s) || false
    rescue => e
      SparrowAuth.logger&.warn("[sparrow_auth] tor_exits lookup_failed class=#{e.class}")
      false
    end

    # Fetches the list and replaces the cached one. Returns how many addresses
    # it stored, or raises and leaves the old list where it was.
    def refresh!
      addresses = parse(fetch)
      raise Error, "the Tor exit list has only #{addresses.size} addresses" if addresses.size < MINIMUM_SIZE

      Rails.cache.write(CACHE_KEY, addresses, expires_in: TTL)
      addresses.size
    end

    # One address per line. Normalised through IPAddr so an IPv6 exit matches
    # however Rails happens to print remote_ip; anything that is not an address
    # is dropped.
    def parse(body)
      body.each_line.filter_map do |line|
        IPAddr.new(line.strip).to_s
      rescue IPAddr::Error
        nil
      end.to_set
    end

    def fetch
      response = Net::HTTP.start(SOURCE_URL.host, SOURCE_URL.port,
        use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.get(SOURCE_URL.request_uri)
      end
      raise Error, "the Tor exit list answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
