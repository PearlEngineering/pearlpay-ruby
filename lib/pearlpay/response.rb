# frozen_string_literal: true

module PearlPay
  # Metadata about the HTTP response that produced an object or error.
  # Headers are allowlisted (only known-safe headers are exposed) and frozen.
  class APIResponse
    # Allowlist, not a denylist: only headers the SDK or its consumers
    # actually need are exposed. Anything not listed here — cookies, auth
    # material, and any header nobody has reviewed for sensitivity — never
    # reaches consumers, including future response headers this SDK
    # doesn't yet know about.
    ALLOWED_HEADERS = %w[
      content-type content-length date retry-after
      x-request-id idempotent-replayed
    ].freeze

    attr_reader :http_status, :headers, :request_id

    def initialize(http_status:, headers:, request_id: nil)
      @http_status = http_status
      @headers = sanitize(headers)
      # The server's own X-Request-Id wins when present (it's what server-side
      # logs are keyed on); the SDK-generated id is only a fallback for when a
      # load balancer or the server itself drops the response header.
      @request_id = @headers["x-request-id"] || request_id
      freeze
    end

    # True when the server replayed a cached idempotent outcome — set on
    # success replays AND error replays.
    def idempotent_replay?
      @headers["idempotent-replayed"] == "true"
    end

    private

    def sanitize(headers)
      (headers || {}).each_with_object({}) do |(key, value), out|
        k = key.to_s.downcase
        next unless ALLOWED_HEADERS.include?(k)

        out[k] = value.to_s
      end.freeze
    end
  end

  module Http
    # Minimal transport-level response passed from an Http::Client to the
    # Requestor. Not part of the public API.
    Response = Struct.new(:status, :headers, :body, keyword_init: true)
  end
end
