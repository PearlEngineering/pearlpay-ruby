# frozen_string_literal: true

require "uri"

module PearlPay
  # Immutable client configuration. Frozen after construction; safe to share
  # across threads. #inspect/#to_s never reveal api_key or signing_secret.
  class Configuration
    DEFAULT_API_BASE = "https://api.pearlpay.io"
    LOCAL_HOSTS = ["localhost", "127.0.0.1", "::1", "[::1]"].freeze

    attr_reader :api_key, :signing_secret, :api_base, :max_network_retries,
                :open_timeout, :read_timeout, :instrumentation

    def initialize(api_key:, signing_secret: nil, api_base: DEFAULT_API_BASE,
                   max_network_retries: 2, open_timeout: 5, read_timeout: 15,
                   instrumentation: nil)
      unless api_key.is_a?(String) && !api_key.empty?
        raise ConfigurationError, "api_key is required and must be a non-empty String"
      end
      if !signing_secret.nil? && !(signing_secret.is_a?(String) && !signing_secret.empty?)
        raise ConfigurationError, "signing_secret must be a non-empty String when given"
      end
      unless max_network_retries.is_a?(Integer) && max_network_retries >= 0
        raise ConfigurationError, "max_network_retries must be a non-negative Integer"
      end
      if instrumentation && !instrumentation.respond_to?(:call)
        raise ConfigurationError, "instrumentation must respond to #call"
      end

      @api_key = -api_key
      @signing_secret = signing_secret && -signing_secret
      @api_base = normalize_api_base(api_base)
      @max_network_retries = max_network_retries
      @open_timeout = validate_timeout(:open_timeout, open_timeout)
      @read_timeout = validate_timeout(:read_timeout, read_timeout)
      @instrumentation = instrumentation
      freeze
    end

    def inspect
      "#<PearlPay::Configuration api_base=#{@api_base.inspect} api_key=[REDACTED] " \
        "signing_secret=#{@signing_secret ? '[REDACTED]' : 'nil'} " \
        "max_network_retries=#{@max_network_retries} " \
        "open_timeout=#{@open_timeout} read_timeout=#{@read_timeout}>"
    end
    alias to_s inspect

    private

    # Timeouts are seconds, not money — Floats are fine here.
    def validate_timeout(name, value)
      unless value.is_a?(Numeric) && value.positive?
        raise ConfigurationError,
              "#{name} must be a positive number of seconds"
      end

      value
    end

    def normalize_api_base(base)
      raise ConfigurationError, "api_base must be a String" unless base.is_a?(String)

      base = base.chomp("/")
      if base.end_with?("/v1")
        Util.warn_once(:api_base_v1,
                       "api_base should be an origin only (the SDK owns the /v1 prefix); " \
                       "stripping trailing /v1 from the configured value")
        base = base.delete_suffix("/v1")
      end

      uri = begin
        URI.parse(base)
      rescue URI::InvalidURIError
        raise ConfigurationError, "api_base is not a valid URL"
      end

      unless uri.is_a?(URI::HTTP) && uri.host
        raise ConfigurationError, "api_base must be an http(s) URL with a host"
      end
      if uri.scheme == "http" && !LOCAL_HOSTS.include?(uri.host.downcase)
        raise ConfigurationError,
              "api_base must use https (plain http is allowed only for localhost)"
      end
      unless uri.path.empty? || uri.path == "/"
        raise ConfigurationError,
              "api_base must be an origin only (no path); the SDK owns the /v1 prefix"
      end
      if uri.query || uri.fragment || uri.userinfo
        raise ConfigurationError, "api_base must be a bare origin (no query, fragment, or userinfo)"
      end

      origin = "#{uri.scheme}://#{uri.host}"
      origin << ":#{uri.port}" unless uri.port == uri.default_port
      -origin
    end
  end
end
