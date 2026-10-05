# frozen_string_literal: true

module PearlPay
  # The only component allowed to schedule a retry. Retry classification is
  # per-operation metadata (retry_class), never decided ad hoc in resources.
  #
  #   :read                      — every GET: transport, 429, and 5xx retry.
  #   :idempotent_transport_only — keyed creates: transport and 429 retry
  #                                (same key, same frozen bytes, fresh signing);
  #                                received 5xx NEVER retries;
  #                                409 idempotency_in_progress gets <= 2 short waits.
  #   :natural                   — server-side converge-to-state writes:
  #                                transport, 429, and 5xx retry.
  #   :never                     — zero retries of any kind (clone/create mint
  #                                duplicates; rotations are destructive).
  #
  # A server Retry-After is honoured only up to +max_retry_after+ seconds; a
  # longer one turns the retry into a raise so a synchronous call never sleeps
  # for minutes. The cap is enforced only in #response_decision; #delay is a
  # pure "Retry-After or jittered backoff" function.
  class RetryPolicy
    BASE_DELAY = 0.5
    MAX_DELAY = 8.0
    MAX_IN_PROGRESS_RETRIES = 2
    IN_PROGRESS_DELAY = 1.0
    # The API sends Retry-After: 60 on every 429 and 5 on a 503, so 60 keeps
    # every documented value honoured while bounding the (up to 3600s) worst case.
    DEFAULT_MAX_RETRY_AFTER = 60

    RETRY_CLASSES = %i[read idempotent_transport_only natural never].freeze

    def initialize(max_retries:, max_retry_after: DEFAULT_MAX_RETRY_AFTER, rng: Random.new)
      @max_retries = max_retries
      @max_retry_after = max_retry_after
      @rng = rng
    end

    attr_reader :max_retries, :max_retry_after

    # Integer delta-seconds Retry-After as a positive Float, else nil. HTTP-dates,
    # fractional, malformed, zero, and negative values are nil (the API only sends integer
    # seconds) and fall back to jittered backoff, which is bounded at MAX_DELAY.
    def self.parse_retry_after(value)
      return nil unless value.is_a?(String) || value.is_a?(Numeric)

      str = value.to_s
      return nil unless str.match?(/\A\s*\d+\s*\z/)

      seconds = str.to_f
      seconds.positive? ? seconds : nil
    end

    def retry_transport?(retry_class, retries_so_far)
      return false if retry_class == :never

      retries_so_far < @max_retries
    end

    # Decision for a received HTTP error response:
    #   :raise, :retry (consumes a network retry), or :retry_in_progress
    #   (the one retryable 409; its own counter, capped at 2).
    # +retry_after+ is the parsed Retry-After (Float or nil); a :retry whose
    # server-requested wait exceeds max_retry_after becomes :raise.
    def response_decision(retry_class, status:, code:, retries_so_far:, in_progress_retries:,
                          retry_after: nil)
      return :raise if retry_class == :never

      return retry_or_raise(retries_so_far, retry_after) if status == 429

      if status >= 500
        case retry_class
        when :read, :natural
          return retry_or_raise(retries_so_far, retry_after)
        else
          return :raise # never auto-retry a received 5xx on a keyed create
        end
      end

      if status == 409 && code == "idempotency_in_progress" && retry_class == :idempotent_transport_only
        return in_progress_retries < MAX_IN_PROGRESS_RETRIES ? :retry_in_progress : :raise
      end

      :raise
    end

    # Exponential backoff with full jitter; a server Retry-After wins. Takes the
    # raw header or an already-parsed Float. Never clamps — see #response_decision.
    def delay(retries_so_far, retry_after: nil)
      parsed = retry_after.is_a?(Numeric) ? retry_after.to_f : self.class.parse_retry_after(retry_after)
      return parsed if parsed&.positive?

      cap = [MAX_DELAY, BASE_DELAY * (2**retries_so_far)].min
      @rng.rand * cap
    end

    def in_progress_delay
      IN_PROGRESS_DELAY
    end

    private

    def retry_or_raise(retries_so_far, retry_after)
      return :raise unless retries_so_far < @max_retries
      return :raise if retry_after && retry_after > @max_retry_after

      :retry
    end
  end
end
