# frozen_string_literal: true

module PearlPay
  # Emits one frozen, allowlist-built event Hash per HTTP attempt to the
  # client's +instrumentation+ hook. Never raw headers, bodies, or secrets.
  # A failing hook must never break the request.
  module Instrumentation
    KEYS = %i[
      sdk_version ruby_version api_version resource operation method path
      status duration_ms attempt retry_count request_id
      idempotency_key_present idempotent_replay error_code
    ].freeze

    module_function

    def event(resource:, operation:, method:, path:, status:, duration_ms:,
              attempt:, request_id:, idempotency_key_present:,
              idempotent_replay:, error_code:)
      {
        sdk_version: VERSION,
        ruby_version: RUBY_VERSION,
        api_version: API_VERSION,
        resource: resource,
        operation: operation,
        method: method,
        path: path,
        status: status,
        duration_ms: duration_ms,
        attempt: attempt,
        retry_count: attempt - 1,
        request_id: request_id,
        idempotency_key_present: idempotency_key_present,
        idempotent_replay: idempotent_replay,
        error_code: error_code
      }.freeze
    end

    def emit(hook, event)
      return unless hook

      hook.call(event)
    rescue StandardError => e
      Util.warn_once(:instrumentation_hook, "instrumentation hook raised #{e.class}; " \
                                            "further hook errors will be ignored silently")
    end
  end
end
