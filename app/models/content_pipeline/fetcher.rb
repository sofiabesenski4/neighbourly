require "resolv"
require "ipaddr"

module ContentPipeline
  # Fetches raw content from a Source's URL over HTTP.
  # Returns the response body as a string.
  class Fetcher
    ALLOWED_SCHEMES = %w[http https].freeze

    # Ranges that should never be reachable from a user-supplied URL. IPAddr
    # covers loopback, private and link-local itself; these are the ones it has
    # no predicate for. 169.254.169.254 (cloud instance metadata) falls under
    # link-local, which is the single most important one to keep blocked.
    BLOCKED_RANGES = [
      IPAddr.new("0.0.0.0/8"),      # "this network"
      IPAddr.new("100.64.0.0/10"),  # carrier-grade NAT
      IPAddr.new("192.0.0.0/24"),   # IETF protocol assignments
      IPAddr.new("192.0.2.0/24"),   # TEST-NET-1
      IPAddr.new("198.18.0.0/15"),  # benchmarking
      IPAddr.new("240.0.0.0/4"),    # reserved
      IPAddr.new("::/128"),         # unspecified
      IPAddr.new("64:ff9b::/96")    # IPv4/IPv6 translation
    ].freeze

    def initialize(source)
      @source = source
    end

    def call
      uri = validated_uri
      response = Net::HTTP.get_response(uri)

      unless response.is_a?(Net::HTTPSuccess)
        raise FetchError, "Failed to fetch #{@source.url}: HTTP #{response.code}"
      end

      response.body
    end

    class FetchError < StandardError; end

    private

    # A Source URL is operator-supplied rather than public input, but it is still
    # a URL this server will dereference, so treat it as untrusted: restrict the
    # scheme, and refuse anything resolving inside our own network or to a cloud
    # metadata endpoint. Net::HTTP.get_response does not follow redirects, so a
    # 3xx to an internal host cannot slip past this check.
    def validated_uri
      uri = URI.parse(@source.url)

      unless ALLOWED_SCHEMES.include?(uri.scheme)
        raise FetchError, "Refusing to fetch #{@source.url}: only http and https are allowed"
      end

      if uri.host.blank?
        raise FetchError, "Refusing to fetch #{@source.url}: no host"
      end

      addresses = resolve(uri.host)

      if addresses.empty?
        raise FetchError, "Refusing to fetch #{@source.url}: host did not resolve"
      end

      if addresses.any? { |address| blocked?(address) }
        raise FetchError, "Refusing to fetch #{@source.url}: host resolves to a non-public address"
      end

      uri
    rescue URI::InvalidURIError => e
      raise FetchError, "Refusing to fetch #{@source.url}: #{e.message}"
    end

    def resolve(host)
      Resolv.getaddresses(host).filter_map do |address|
        IPAddr.new(address)
      rescue IPAddr::InvalidAddressError
        nil
      end
    end

    def blocked?(address)
      return true if address.loopback? || address.private? || address.link_local?

      BLOCKED_RANGES.any? { |range| range.include?(address) }
    end
  end
end
