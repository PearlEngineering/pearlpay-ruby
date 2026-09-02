# frozen_string_literal: true

module PearlPay
  # The explicit, immutable, thread-safe entry point. One instance is safely
  # shareable across Puma/Sidekiq/Lambda threads; there is no global default
  # client and no mutable module configuration.
  class Client
    RAW_SIGNING_MODES = %i[never if_configured required].freeze

    attr_reader :config, :v1

    def initialize(api_key:, signing_secret: nil,
                   api_base: Configuration::DEFAULT_API_BASE,
                   max_network_retries: 2, open_timeout: 5, read_timeout: 15,
                   instrumentation: nil, http_client: nil)
      @config = Configuration.new(
        api_key: api_key, signing_secret: signing_secret, api_base: api_base,
        max_network_retries: max_network_retries, open_timeout: open_timeout,
        read_timeout: read_timeout, instrumentation: instrumentation
      )
      @requestor = Requestor.new(@config, **(http_client ? { http_client: http_client } : {}))
      @v1 = V1Services.new(@requestor)
      freeze
    end

    # Escape hatch for endpoints the SDK does not model yet. +path+ is
    # relative to /v1 (e.g. "/payments/pay_123"); the SDK owns the /v1 prefix.
    # Goes through the exact same pipeline as every resource service.
    #
    # opts additionally accepts:
    #   retry_class: — declares retry behaviour (default :read for GET,
    #                  :never for writes; never decided ad hoc)
    #   signing:     — :never (default), :if_configured, or :required
    def raw_request(method, path, params: nil, opts: {})
      verb = method.to_s.upcase
      unless Http::NetHttpClient::VERB_CLASSES.key?(verb)
        raise ArgumentError, "unsupported HTTP method: #{method.inspect}"
      end
      unless path.is_a?(String) && path.start_with?("/")
        raise ArgumentError, "path must be a String starting with \"/\" (relative to /v1)"
      end
      if path == "/v1" || path.start_with?("/v1/")
        raise ArgumentError, "path is relative to /v1 — pass #{path.delete_prefix('/v1').inspect}, " \
                             "not #{path.inspect}"
      end

      opts = opts.transform_keys(&:to_sym)
      retry_class = opts.delete(:retry_class) || (verb == "GET" ? :read : :never)
      signing = opts.delete(:signing) || :never
      unless RetryPolicy::RETRY_CLASSES.include?(retry_class)
        raise ArgumentError, "retry_class must be one of #{RetryPolicy::RETRY_CLASSES.join(', ')}"
      end
      unless RAW_SIGNING_MODES.include?(signing)
        raise ArgumentError, "signing must be one of #{RAW_SIGNING_MODES.join(', ')}"
      end

      operation = Operation.new(
        resource: "raw", name: "raw_request", method: verb, path: path,
        retry_class: retry_class, signing: signing, idempotency: :none
      )
      if verb == "GET"
        @requestor.execute(operation, query: params, opts: opts)
      else
        @requestor.execute(operation, params: params, opts: opts)
      end
    end

    def inspect
      "#<PearlPay::Client api_base=#{@config.api_base.inspect} api_key=[REDACTED] " \
        "signing_secret=#{@config.signing_secret ? '[REDACTED]' : 'nil'}>"
    end
    alias to_s inspect
  end
end
