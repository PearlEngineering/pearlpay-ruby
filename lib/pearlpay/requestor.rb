# frozen_string_literal: true

require "json"
require "uri"

module PearlPay
  # Metadata for one API operation. Resource services contain paths, verbs,
  # params, and this metadata only — every request flows through Requestor.
  # The :method member (the HTTP verb) deliberately shadows Struct#method.
  Operation = Struct.new(:resource, :name, :method, :path, :retry_class, # rubocop:disable Lint/StructNewOverride
                         :signing, :idempotency, :read_timeout, keyword_init: true) do
    def qualified_name
      "#{resource}.#{name}"
    end
  end

  # The single request pipeline: serialization -> auth header -> standard
  # headers -> optional HMAC signing -> timeouts -> retry policy -> parse ->
  # error mapping -> instrumentation. All per-request state is local to the
  # #execute call; one Requestor is safely shared across threads.
  class Requestor
    TRANSPORT_TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze
    TRANSPORT_CONNECTION_ERRORS = [
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::EPIPE,
      SocketError, EOFError, IOError, OpenSSL::SSL::SSLError
    ].freeze

    # Headers the SDK sets for identity, auth, versioning, or request
    # integrity. A caller-supplied header with one of these names (any
    # case — HTTP header names are case-insensitive) is dropped rather
    # than allowed to override the SDK's own value.
    RESERVED_HEADER_NAMES = %w[
      authorization host x-api-version x-request-id idempotency-key
      x-request-timestamp x-request-nonce x-signature
    ].freeze

    def initialize(config, http_client: Http::NetHttpClient.new,
                   sleeper: ->(seconds) { Kernel.sleep(seconds) }, rng: Random.new)
      @config = config
      @http_client = http_client
      @sleeper = sleeper
      @rng = rng
      freeze
    end

    attr_reader :config

    def execute(operation, params: nil, query: nil, opts: {})
      options = opts.is_a?(RequestOptions) ? opts : RequestOptions.new(opts)

      Util.reject_floats!(params) if params
      Util.reject_floats!(query, "query") if query

      body = serialize_body(operation, params)
      idempotency_key = resolve_idempotency_key(operation, options)
      signing_secret = resolve_signing_secret(operation)
      query = query&.transform_keys(&:to_s)
      uri = build_uri(operation, query)

      policy = RetryPolicy.new(
        max_retries: options.max_network_retries || @config.max_network_retries, rng: @rng
      )
      open_timeout = options.open_timeout || @config.open_timeout
      read_timeout = options.read_timeout || operation.read_timeout || @config.read_timeout

      retries = 0
      in_progress_retries = 0
      attempt = 0

      loop do
        attempt += 1
        request_id = Util.uuid
        headers = build_headers(operation, body: body, options: options,
                                           idempotency_key: idempotency_key,
                                           signing_secret: signing_secret, request_id: request_id)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          raw = @http_client.execute(method: operation.method, uri: uri, headers: headers,
                                     body: body, open_timeout: open_timeout,
                                     read_timeout: read_timeout)
        rescue *TRANSPORT_TIMEOUT_ERRORS, *TRANSPORT_CONNECTION_ERRORS => e
          instrument(operation, status: nil, started: started, attempt: attempt,
                                request_id: request_id, idempotency_key: idempotency_key,
                                idempotent_replay: false, error_code: transport_error_code(e))
          if policy.retry_transport?(operation.retry_class, retries)
            @sleeper.call(policy.delay(retries))
            retries += 1
            next
          end
          raise transport_error(e, uri)
        end

        api_response = APIResponse.new(http_status: raw.status, headers: raw.headers)

        if (200..299).cover?(raw.status)
          instrument(operation, status: raw.status, started: started, attempt: attempt,
                                request_id: request_id, idempotency_key: idempotency_key,
                                idempotent_replay: api_response.idempotent_replay?, error_code: nil)
          return build_success(operation, raw, api_response, query: query, opts: options)
        end

        if (300..399).cover?(raw.status)
          code = "http_#{raw.status}"
          instrument(operation, status: raw.status, started: started, attempt: attempt,
                                request_id: request_id, idempotency_key: idempotency_key,
                                idempotent_replay: false, error_code: code)
          raise APIError.new(
            "server responded with a redirect (HTTP #{raw.status}); the SDK does not follow redirects",
            code: code, http_status: raw.status, request_id: api_response.request_id,
            last_response: api_response
          )
        end

        envelope = parse_error_envelope(raw)
        instrument(operation, status: raw.status, started: started, attempt: attempt,
                              request_id: request_id, idempotency_key: idempotency_key,
                              idempotent_replay: api_response.idempotent_replay?,
                              error_code: envelope[:code])

        case policy.response_decision(operation.retry_class, status: raw.status,
                                                             code: envelope[:code], retries_so_far: retries,
                                                             in_progress_retries: in_progress_retries)
        when :retry
          @sleeper.call(policy.delay(retries, retry_after: raw.headers && raw.headers["retry-after"]))
          retries += 1
        when :retry_in_progress
          @sleeper.call(policy.in_progress_delay)
          in_progress_retries += 1
        else
          raise build_api_error(raw.status, envelope, api_response)
        end
      end
    end

    private

    # Serialize once per logical call; every retry resends these exact bytes.
    def serialize_body(operation, params)
      return nil unless %w[POST PATCH PUT].include?(operation.method) && params

      JSON.generate(params).freeze
    end

    def resolve_idempotency_key(operation, options)
      case operation.idempotency
      when :required
        key = options.idempotency_key
        unless key
          raise ArgumentError,
                "idempotency_key is required for #{operation.qualified_name} " \
                "(the SDK never generates keys for money movement)"
        end
        key
      when :auto
        # One UUID per logical call — stable across the SDK's internal retries.
        options.idempotency_key || Util.uuid
      else
        options.idempotency_key
      end
    end

    def resolve_signing_secret(operation)
      case operation.signing
      when :required
        secret = @config.signing_secret
        unless secret
          raise ConfigurationError,
                "#{operation.qualified_name} requires request signing: construct the client " \
                "with signing_secret: (no request was sent)"
        end
        secret
      when :if_configured
        @config.signing_secret
      end
    end

    def reject_reserved(user_headers)
      user_headers.reject { |k, _| RESERVED_HEADER_NAMES.include?(k.to_s.downcase) }
    end

    def build_uri(operation, query)
      url = "#{@config.api_base}/v1#{operation.path}"
      if query && !query.empty?
        pairs = query.compact
        url << "?#{URI.encode_www_form(pairs)}" unless pairs.empty?
      end
      URI.parse(url)
    end

    def build_headers(_operation, body:, options:, idempotency_key:, signing_secret:, request_id:)
      headers = {
        "Authorization" => "Bearer #{@config.api_key}",
        "Accept" => "application/json",
        "User-Agent" => "pearlpay-ruby/#{VERSION} ruby/#{RUBY_VERSION}",
        "X-Request-Id" => request_id,
        "X-Api-Version" => API_VERSION
      }
      headers["Content-Type"] = "application/json" if body
      headers.merge!(reject_reserved(options.headers)) if options.headers
      headers["Idempotency-Key"] = idempotency_key if idempotency_key
      # Fresh timestamp + nonce + signature on every attempt (nonces are single-use).
      headers.merge!(RequestSignature.headers(secret: signing_secret, body: body)) if signing_secret
      headers
    end

    def build_success(operation, raw, api_response, query:, opts:)
      parsed = parse_json_body(raw, api_response)
      return parsed unless parsed.is_a?(Hash)

      if list_response?(parsed)
        fetcher = if operation.method == "GET"
                    lambda do |extra_query|
                      execute(operation, query: (query || {}).merge(extra_query), opts: opts)
                    end
                  end
        ListObject.new(parsed, api_response, next_page_fetcher: fetcher)
      else
        Object.new(parsed, api_response)
      end
    end

    def list_response?(parsed)
      parsed["object"] == "list" ||
        (parsed["data"].is_a?(Array) && parsed.key?("meta"))
    end

    def parse_json_body(raw, api_response)
      body = raw.body.to_s
      return {} if body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      raise APIError.new(
        "server returned HTTP #{raw.status} with a body that is not valid JSON",
        code: "http_#{raw.status}", http_status: raw.status,
        request_id: api_response.request_id, last_response: api_response
      )
    end

    def parse_error_envelope(raw)
      parsed = begin
        raw.body.to_s.empty? ? nil : JSON.parse(raw.body)
      rescue JSON::ParserError
        nil
      end
      error = parsed.is_a?(Hash) ? parsed["error"] : nil
      if error.is_a?(Hash) && error["code"]
        {
          code: error["code"],
          message: error["message"] || "HTTP #{raw.status}",
          details: error["details"],
          request_id: error["request_id"]
        }
      else
        # Non-JSON responses (e.g. load balancers): synthesize code "http_<status>".
        { code: "http_#{raw.status}", message: "HTTP #{raw.status}", details: nil, request_id: nil }
      end
    end

    def build_api_error(status, envelope, api_response)
      klass = APIError.classify(status, envelope[:code])
      klass.new(
        envelope[:message],
        code: envelope[:code], http_status: status,
        request_id: envelope[:request_id] || api_response.request_id,
        details: envelope[:details], last_response: api_response
      )
    end

    def transport_error_code(exception)
      TRANSPORT_TIMEOUT_ERRORS.any? { |k| exception.is_a?(k) } ? "timeout" : "connection_error"
    end

    def transport_error(exception, uri)
      if TRANSPORT_TIMEOUT_ERRORS.any? { |k| exception.is_a?(k) }
        TimeoutError.new("request to #{uri.host} timed out (#{exception.class})")
      else
        ConnectionError.new("connection to #{uri.host} failed (#{exception.class}: #{exception.message})")
      end
    end

    def instrument(operation, status:, started:, attempt:, request_id:,
                   idempotency_key:, idempotent_replay:, error_code:)
      hook = @config.instrumentation
      return unless hook

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0).round(2)
      Instrumentation.emit(hook, Instrumentation.event(
                                   resource: operation.resource, operation: operation.name,
                                   method: operation.method, path: "/v1#{operation.path}",
                                   status: status, duration_ms: duration_ms, attempt: attempt,
                                   request_id: request_id,
                                   idempotency_key_present: !idempotency_key.nil?,
                                   idempotent_replay: idempotent_replay, error_code: error_code
                                 ))
    end
  end
end
