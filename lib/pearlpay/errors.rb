# frozen_string_literal: true

module PearlPay
  class Error < StandardError; end

  # Raised locally, before any network request (missing signing secret,
  # invalid api_base, bad option values).
  class ConfigurationError < Error; end

  # Transport failure — no HTTP response was received.
  class ConnectionError < Error; end

  # Timeout establishing the connection or reading the response.
  class TimeoutError < ConnectionError; end

  # Raised by PearlPay::Webhook.verify! Carries a machine-readable +reason+:
  # :invalid, :stale_timestamp, or :malformed.
  class WebhookSignatureError < Error
    attr_reader :reason

    def initialize(message, reason:)
      @reason = reason
      super(message)
    end
  end

  # Any HTTP error response from the API.
  class APIError < Error
    attr_reader :code, :http_status, :request_id, :details, :last_response

    def initialize(message, code: nil, http_status: nil, request_id: nil,
                   details: nil, last_response: nil)
      @code = code
      @http_status = http_status
      @request_id = request_id
      @details = details
      @last_response = last_response
      super(message)
    end

    def idempotent_replay?
      last_response ? last_response.idempotent_replay? : false
    end

    # Classification is by error code + HTTP status only — never message text.
    def self.classify(http_status, code)
      case http_status
      when 400, 422
        %w[invalid_parameter missing_parameter].include?(code) ? ValidationError : InvalidRequestError
      when 401
        code == "invalid_signature" ? SignatureError : AuthenticationError
      when 403 then PermissionError
      when 404 then NotFoundError
      when 409
        case code
        when "duplicate_reference" then DuplicateReferenceError
        when "idempotency_conflict" then IdempotencyConflictError
        when "idempotency_in_progress" then IdempotencyInProgressError
        else ConflictError
        end
      when 410 then InvalidRequestError
      when 429 then RateLimitError
      when 502
        code == "upstream_failure" ? UpstreamError : APIError
      else
        APIError
      end
    end
  end

  class AuthenticationError < APIError; end
  class SignatureError < AuthenticationError; end
  class PermissionError < APIError; end

  class InvalidRequestError < APIError; end
  class ValidationError < InvalidRequestError; end

  class NotFoundError < APIError; end

  class ConflictError < APIError; end
  class DuplicateReferenceError < ConflictError; end
  class IdempotencyConflictError < ConflictError; end
  class IdempotencyInProgressError < ConflictError; end

  class RateLimitError < APIError
    # Seconds to wait before retrying, from the Retry-After header (nil if absent).
    def retry_after
      value = last_response && last_response.headers["retry-after"]
      value&.to_i
    end
  end

  class UpstreamError < APIError; end
end
