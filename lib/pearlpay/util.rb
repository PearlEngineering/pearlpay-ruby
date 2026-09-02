# frozen_string_literal: true

require "securerandom"
require "uri"

module PearlPay
  module Util
    module_function

    def uuid
      SecureRandom.uuid
    end

    def path_escape(segment)
      raise ArgumentError, "id must be a non-empty String" unless segment.is_a?(String) && !segment.empty?

      URI.encode_uri_component(segment)
    end

    # Amounts are integer minor units (centavos). Floats are never valid
    # anywhere in a request; reject them locally, before any network call,
    # naming the integer the caller probably meant.
    def reject_floats!(value, path = "params")
      case value
      when Float
        raise ArgumentError, float_message(value, path)
      when Hash
        value.each { |k, v| reject_floats!(v, "#{path}[#{k.inspect}]") }
      when Array
        value.each_with_index { |v, i| reject_floats!(v, "#{path}[#{i}]") }
      end
    end

    def float_message(value, path)
      if (value % 1).zero?
        "#{path} is a Float; amounts are integer minor units (centavos) — " \
          "pass #{value.to_i}, not #{value}"
      else
        centavos = (value.rationalize(Rational(1, 10_000)) * 100).round
        "#{path} is a Float; amounts are integer minor units (centavos) — " \
          "if you meant #{value} PHP, pass #{centavos}"
      end
    end

    # One-time warnings (e.g. api_base ending in /v1). Process-global,
    # mutex-guarded; deliberately outside Client/Configuration so those stay
    # immutable after construction.
    WARN_MUTEX = Mutex.new
    @warned = {}

    def warn_once(key, message)
      WARN_MUTEX.synchronize do
        return if @warned[key]

        @warned[key] = true
      end
      Kernel.warn("pearlpay: #{message}")
    end

    def reset_warnings! # :nodoc: test hook
      WARN_MUTEX.synchronize { @warned = {} }
    end
  end
end
