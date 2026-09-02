# frozen_string_literal: true

require "digest"
require "openssl"
require "securerandom"

module PearlPay
  # Request signing for the /v1 API: HMAC-SHA256 over
  # "#{timestamp}.#{nonce}.#{SHA256(body_bytes)}".
  #
  # This scheme is deliberately distinct from webhook verification
  # (PearlPay::Webhook::Signature, which signs the raw body, not its digest).
  # The two must never be conflated.
  module RequestSignature
    SCHEME = "v1"

    module_function

    # Returns the three signing headers for one attempt. Callers must invoke
    # this freshly per attempt: nonces are single-use server-side.
    def headers(secret:, body:, timestamp: Time.now.to_i, nonce: SecureRandom.hex(16))
      {
        "X-Request-Timestamp" => timestamp.to_s,
        "X-Request-Nonce" => nonce,
        "X-Signature" => signature(secret: secret, body: body, timestamp: timestamp, nonce: nonce)
      }
    end

    def signature(secret:, body:, timestamp:, nonce:)
      body_hash = Digest::SHA256.hexdigest(body || "")
      message = "#{timestamp}.#{nonce}.#{body_hash}"
      "#{SCHEME}=#{OpenSSL::HMAC.hexdigest('SHA256', secret, message)}"
    end
  end
end
