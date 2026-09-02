# frozen_string_literal: true

module PearlPay
  # Per-call options, accepted as +opts:+ on every service method:
  # idempotency_key:, headers:, open_timeout:, read_timeout:,
  # max_network_retries:. Validated locally; unknown keys raise.
  class RequestOptions
    ALLOWED_KEYS = %i[idempotency_key headers open_timeout read_timeout max_network_retries].freeze

    attr_reader :idempotency_key, :headers, :open_timeout, :read_timeout, :max_network_retries

    def initialize(opts)
      raise ArgumentError, "opts must be a Hash" unless opts.is_a?(Hash)

      unknown = opts.keys.map(&:to_sym) - ALLOWED_KEYS
      unless unknown.empty?
        raise ArgumentError, "unknown option(s): #{unknown.join(', ')} " \
                             "(allowed: #{ALLOWED_KEYS.join(', ')})"
      end

      opts = opts.transform_keys(&:to_sym)
      @idempotency_key = validate_idempotency_key(opts[:idempotency_key])
      @headers = validate_headers(opts[:headers])
      @open_timeout = validate_timeout(:open_timeout, opts[:open_timeout])
      @read_timeout = validate_timeout(:read_timeout, opts[:read_timeout])
      @max_network_retries = validate_retries(opts[:max_network_retries])
      freeze
    end

    private

    def validate_idempotency_key(key)
      return nil if key.nil?
      unless key.is_a?(String) && !key.empty? && key.length <= 255
        raise ArgumentError, "idempotency_key must be a non-empty String of at most 255 characters"
      end

      key
    end

    def validate_headers(headers)
      return nil if headers.nil?
      raise ArgumentError, "headers must be a Hash" unless headers.is_a?(Hash)

      headers.to_h { |k, v| [k.to_s, v.to_s] }
    end

    def validate_timeout(name, value)
      return nil if value.nil?
      unless value.is_a?(Numeric) && value.positive?
        raise ArgumentError,
              "#{name} must be a positive number of seconds"
      end

      value
    end

    def validate_retries(value)
      return nil if value.nil?
      unless value.is_a?(Integer) && value >= 0
        raise ArgumentError,
              "max_network_retries must be a non-negative Integer"
      end

      value
    end
  end
end
