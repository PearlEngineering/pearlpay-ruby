# frozen_string_literal: true

require "json"
require "openssl"

module PearlPay
  # Webhook delivery verification: HMAC-SHA256 over "#{timestamp}.#{raw_body}"
  # (the raw body itself — NOT its digest, unlike request signing; the two
  # schemes are deliberately separate implementations).
  module Webhook
    module_function

    # Verifies a webhook delivery and returns the event as a PearlPay::Object.
    # +payload+ must be the exact raw request body bytes — never re-parsed or
    # re-serialized JSON. Raises PearlPay::WebhookSignatureError on failure.
    def verify!(payload:, timestamp:, signature:, secret:, tolerance: 300)
      Signature.verify!(payload: payload, timestamp: timestamp,
                        signature: signature, secret: secret, tolerance: tolerance)
      data = begin
        JSON.parse(payload)
      rescue JSON::ParserError
        raise WebhookSignatureError.new("webhook payload is not valid JSON", reason: :malformed)
      end
      unless data.is_a?(Hash)
        raise WebhookSignatureError.new("webhook payload is not a JSON object",
                                        reason: :malformed)
      end

      Object.new(data)
    end

    module Signature
      SCHEME_PREFIX = "v1="
      HEX_DIGEST_LENGTH = 64

      module_function

      def verify!(payload:, timestamp:, signature:, secret:, tolerance: 300)
        malformed!("payload must be a String") unless payload.is_a?(String)
        malformed!("secret must be a non-empty String") unless secret.is_a?(String) && !secret.empty?

        ts = parse_timestamp(timestamp)
        hex = parse_signature(signature)

        expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{payload}")
        unless secure_compare(expected, hex)
          raise WebhookSignatureError.new("webhook signature verification failed", reason: :invalid)
        end

        if (Time.now.to_i - ts).abs > tolerance
          raise WebhookSignatureError.new(
            "webhook timestamp outside tolerance (#{tolerance}s)", reason: :stale_timestamp
          )
        end

        true
      end

      def parse_timestamp(timestamp)
        malformed!("timestamp header is missing") if timestamp.nil?
        string = timestamp.is_a?(Integer) ? timestamp.to_s : timestamp
        unless string.is_a?(String) && string.match?(/\A\d+\z/)
          malformed!("timestamp must be an integer string")
        end
        string.to_i
      end

      def parse_signature(signature)
        malformed!("signature header is missing") if signature.nil?
        malformed!("signature must be a String") unless signature.is_a?(String)
        malformed!("signature must use the v1= scheme") unless signature.start_with?(SCHEME_PREFIX)
        hex = signature.delete_prefix(SCHEME_PREFIX)
        malformed!("signature must be v1= followed by 64 hex characters") unless hex.match?(/\A\h{64}\z/)
        hex
      end

      # Constant-time comparison with a bytesize pre-check.
      def secure_compare(expected, actual)
        return false unless expected.bytesize == actual.bytesize

        OpenSSL.fixed_length_secure_compare(expected, actual)
      end

      def malformed!(message)
        raise WebhookSignatureError.new(message, reason: :malformed)
      end
    end
  end
end
