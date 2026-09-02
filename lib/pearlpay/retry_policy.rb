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
  class RetryPolicy
    BASE_DELAY = 0.5
    MAX_DELAY = 8.0
    MAX_IN_PROGRESS_RETRIES = 2
    IN_PROGRESS_DELAY = 1.0

    RETRY_CLASSES = %i[read idempotent_transport_only natural never].freeze

    def initialize(max_retries:, rng: Random.new)
      @max_retries = max_retries
      @rng = rng
    end

    attr_reader :max_retries

    def retry_transport?(retry_class, retries_so_far)
      return false if retry_class == :never

      retries_so_far < @max_retries
    end

    # Decision for a received HTTP error response:
    #   :raise, :retry (consumes a network retry), or :retry_in_progress
    #   (the one retryable 409; its own counter, capped at 2).
    def response_decision(retry_class, status:, code:, retries_so_far:, in_progress_retries:)
      return :raise if retry_class == :never

      if status == 429
        return retries_so_far < @max_retries ? :retry : :raise
      end

      if status >= 500
        case retry_class
        when :read, :natural
          return retries_so_far < @max_retries ? :retry : :raise
        else
          return :raise # never auto-retry a received 5xx on a keyed create
        end
      end

      if status == 409 && code == "idempotency_in_progress" && retry_class == :idempotent_transport_only
        return in_progress_retries < MAX_IN_PROGRESS_RETRIES ? :retry_in_progress : :raise
      end

      :raise
    end

    # Exponential backoff with full jitter; a server Retry-After wins.
    def delay(retries_so_far, retry_after: nil)
      return retry_after.to_f if retry_after&.to_f&.positive?

      cap = [MAX_DELAY, BASE_DELAY * (2**retries_so_far)].min
      @rng.rand * cap
    end

    def in_progress_delay
      IN_PROGRESS_DELAY
    end
  end
end
